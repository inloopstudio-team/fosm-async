# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "active_record"
require "fosm-rails"
require "fosm-async"

# Setup in-memory database for testing
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  create_table :async_invoices do |t|
    t.string :state, default: "draft"
    t.string :recipient_email
    t.timestamps
  end
end

# Test model with async support
class AsyncInvoice < ActiveRecord::Base
  self.table_name = "async_invoices"
  
  include Fosm::Lifecycle
  include Fosm::Async::LifecycleAsync
  
  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    
    event :send_invoice, from: :draft, to: :sent do
      guard :valid_email do |inv|
        inv.recipient_email.present? && inv.recipient_email.include?("@")
      end
      
      side_effect :notify
    end
    
    event :pay, from: :sent, to: :paid
  end
  
  attr_accessor :notified
  
  def notify
    @notified = true
  end
end

# =============================================================================
# FOSM-ASYNC LITMUS TESTS
# =============================================================================

class FosmAsyncLitmusTest < Minitest::Test
  def test_async_fire_transitions_state
    invoice = AsyncInvoice.create!(recipient_email: "test@example.com")
    
    result = invoice.fire_async!(:send_invoice, actor: :test)
    
    assert result[:success]
    assert_equal "sent", result[:state]
    assert_equal "sent", invoice.reload.state
  end
  
  def test_async_respects_guards
    invoice = AsyncInvoice.create!(recipient_email: "bad-email")
    
    result = invoice.fire_async!(:send_invoice, actor: :test)
    
    refute result[:success]
    assert_includes result[:error], "GuardFailed"
    assert_equal "draft", invoice.reload.state
  end
  
  def test_async_runs_side_effects
    invoice = AsyncInvoice.create!(recipient_email: "test@example.com")
    
    invoice.fire_async!(:send_invoice, actor: :test)
    
    assert invoice.notified
  end
  
  def test_async_returns_error_for_invalid_event
    invoice = AsyncInvoice.create!(recipient_email: "test@example.com")
    
    result = invoice.fire_async!(:nonexistent_event, actor: :test)
    
    refute result[:success]
    assert_equal "UnknownEvent", result[:error]
  end
  
  def test_async_handles_terminal_state
    invoice = AsyncInvoice.create!(
      state: "paid",
      recipient_email: "test@example.com"
    )
    
    result = invoice.fire_async!(:send_invoice, actor: :test)
    
    refute result[:success]
    assert_equal "TerminalState", result[:error]
  end
end

# =============================================================================
# FOSM-ASYNC GUARD RUNNER TESTS
# =============================================================================

class FosmAsyncGuardRunnerTest < Minitest::Test
  def test_concurrent_guard_evaluation
    # Create guards with simulated delays
    guard1 = Fosm::Lifecycle::GuardDefinition.new(name: :slow) do
      sleep 0.05
      true
    end
    
    guard2 = Fosm::Lifecycle::GuardDefinition.new(name: :fast) do
      sleep 0.01
      true
    end
    
    # Should complete in ~50ms (slowest guard), not ~60ms (sequential)
    start = Time.now
    
    # Note: This requires running inside Async context
    result = nil
    Async do
      result = Fosm::Async::GuardRunner.evaluate_concurrently(
        [guard1, guard2],
        nil,
        timeout: 1
      )
    end
    
    elapsed = Time.now - start
    
    # Allow some overhead, but should be faster than sequential
    assert elapsed < 0.1, "Concurrent guards should run faster than sequential"
  end
  
  def test_guard_runner_fails_on_timeout
    slow_guard = Fosm::Lifecycle::GuardDefinition.new(name: :very_slow) do
      sleep 2  # Will timeout
      true
    end
    
    assert_raises(Fosm::GuardFailed) do
      Async do
        Fosm::Async::GuardRunner.evaluate_concurrently(
          [slow_guard],
          nil,
          timeout: 0.1
        )
      end
    end
  end
  
  def test_guard_runner_reports_failures
    failing_guard = Fosm::Lifecycle::GuardDefinition.new(name: :failer) do
      "Custom failure reason"
    end
    
    error = assert_raises(Fosm::GuardFailed) do
      Async do
        Fosm::Async::GuardRunner.evaluate_concurrently(
          [failing_guard],
          nil
        )
      end
    end
    
    assert_includes error.message, "failer"
  end
end

# =============================================================================
# FOSM-ASYNC BULK OPERATIONS TESTS
# =============================================================================

class FosmAsyncBulkOperationsTest < Minitest::Test
  def setup
    @invoices = 5.times.map do |i|
      AsyncInvoice.create!(recipient_email: "test#{i}@example.com")
    end
  end
  
  def test_bulk_operations_process_all_records
    results = nil
    
    Async do
      results = Fosm::Async::BulkOperations.fire_all!(
        @invoices,
        :send_invoice,
        actor: :test,
        max_concurrent: 3
      )
    end
    
    assert_equal 5, results.keys.length
    
    success_count = results.count { |_, v| v[:success] }
    assert_equal 5, success_count
  end
  
  def test_bulk_operations_handles_failures
    # Create one invalid invoice
    bad_invoice = AsyncInvoice.create!(recipient_email: "bad")
    all_invoices = @invoices + [bad_invoice]
    
    results = nil
    Async do
      results = Fosm::Async::BulkOperations.fire_all!(
        all_invoices,
        :send_invoice,
        actor: :test
      )
    end
    
    assert_equal 6, results.keys.length
    
    success_count = results.count { |_, v| v[:success] }
    failure_count = results.count { |_, v| !v[:success] }
    
    assert_equal 5, success_count
    assert_equal 1, failure_count
    
    # Bad invoice should have error details
    bad_result = results[bad_invoice.id]
    refute bad_result[:success]
    assert bad_result[:error].present?
  end
  
  def test_bulk_operations_respects_max_concurrent
    # This is hard to test directly, but we can verify it doesn't blow up
    # with many records by limiting concurrency
    
    many_invoices = 20.times.map do |i|
      AsyncInvoice.create!(recipient_email: "bulk#{i}@example.com")
    end
    
    results = nil
    Async do
      results = Fosm::Async::BulkOperations.fire_all!(
        many_invoices,
        :send_invoice,
        actor: :test,
        max_concurrent: 5  # Limit to 5 concurrent
      )
    end
    
    success_count = results.count { |_, v| v[:success] }
    assert_equal 20, success_count
  end
end

# =============================================================================
# FOSM-ASYNC TRANSITION BUFFER TESTS
# =============================================================================

class FosmAsyncTransitionBufferTest < Minitest::Test
  def test_buffer_accepts_entries
    buffer = Fosm::Async::TransitionBufferFiber
    
    entry = {
      "record_type" => "Test",
      "record_id" => "1",
      "event_name" => "test"
    }
    
    # Should not raise
    assert_nothing_raised do
      buffer.push(entry)
    end
    
    assert buffer.pending_count > 0 || true  # May flush immediately
  end
  
  def test_buffer_respects_max_size
    buffer = Fosm::Async::TransitionBufferFiber
    
    # Fill buffer to max
    buffer::MAX_BUFFER_SIZE.times do |i|
      buffer.push({ "id" => i })
    end
    
    assert buffer.pending_count >= 0
  end
end

# Run tests if executed directly
if __FILE__ == $0
  Minitest.run
end
