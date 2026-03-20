# frozen_string_literal: true

module Fosm
  module Async
    # Fiber-based transition buffer for high-throughput scenarios.
    # Replaces the thread-based TransitionBuffer with fiber-based scheduling.
    #
    # Features:
    #   - No dedicated thread (runs in main async loop)
    #   - Dynamic batch sizing based on load
    #   - Backpressure when buffer is full
    #   - Lower latency under burst load
    #
    class TransitionBufferFiber
      BUFFER = ::Async::Queue.new
      MAX_BUFFER_SIZE = 10_000
      FLUSH_INTERVAL = 1.0

      class << self
        attr_accessor :scheduler

        def push(entry)
          # Backpressure: wait if buffer full
          while BUFFER.size >= MAX_BUFFER_SIZE
            ::Async::Task.yield
          end
          BUFFER << entry
        end

        def start_flusher!
          @scheduler = ::Async::Scheduler.new

          ::Async(@scheduler) do
            loop do
              flush_timer = ::Async::Clock.timeout(FLUSH_INTERVAL) { wait_for_flush_condition }
              flush
            rescue => e
              Rails.logger.error("[Fosm] Buffer flush error: #{e.message}")
            end
          end
        end

        def flush
          batch = []

          # Drain up to batch size (non-blocking)
          while batch.size < batch_size && (entry = BUFFER.try_pop)
            batch << entry
          end

          return if batch.empty?

          # Bulk insert with fiber-aware connection
          ActiveRecord::Base.connection_pool.with_connection do
            Fosm::TransitionLog.insert_all(
              batch.map { |e| e.merge("created_at" => Time.current) }
            )
          end

          Rails.logger.info("[Fosm] Flushed #{batch.size} transition logs")
        end

        def pending_count
          BUFFER.size
        end

        private

        def wait_for_flush_condition
          until should_flush?
            ::Async::Task.yield
          end
        end

        def should_flush?
          BUFFER.size >= batch_size || @force_flush
        end

        def batch_size
          # Dynamic: larger batches under load
          [BUFFER.size / 10, 100].max
        end
      end
    end
  end
end
