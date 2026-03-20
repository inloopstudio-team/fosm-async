# frozen_string_literal: true

module Fosm
  module Async
    # Concurrent guard evaluation using Async::Barrier.
    # Multiple guards run in parallel fibers, reducing latency when guards
    # perform I/O (HTTP calls, DB queries to other databases).
    class GuardRunner
      def self.evaluate_concurrently(guard_definitions, record, timeout: 5)
        return true if guard_definitions.empty?

        barrier = ::Async::Barrier.new
        results = {}

        ::Async do
          guard_definitions.each do |guard_def|
            barrier.async do
              start_time = Time.now
              allowed, reason = guard_def.evaluate(record)
              elapsed = Time.now - start_time

              results[guard_def.name] = {
                allowed: allowed,
                reason: reason,
                elapsed_ms: ((elapsed) * 1000).round(2)
              }
            end
          end

          barrier.wait(timeout: timeout)
        end

        # Check for failures
        failures = results.select { |_, v| !v[:allowed] }
        if failures.any?
          first_failure = failures.first
          raise Fosm::GuardFailed.new(
            first_failure[0],
            "concurrent_evaluation",
            first_failure[1][:reason]
          )
        end

        results
      rescue ::Async::TimeoutError
        raise Fosm::GuardFailed.new("timeout", "concurrent_evaluation", "Guard evaluation exceeded #{timeout}s")
      end
    end
  end
end
