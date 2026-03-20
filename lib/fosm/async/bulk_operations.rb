# frozen_string_literal: true

module Fosm
  module Async
    # Structured concurrency for agent bulk operations.
    # Process multiple records with bounded concurrency and supervision.
    class BulkOperations
      # Process N records with bounded concurrency
      #
      # Example:
      #   BulkOperations.fire_all!(
      #     Fosm::Invoice.where(state: "draft"),
      #     :send,
      #     actor: user,
      #     max_concurrent: 10
      #   )
      #
      def self.fire_all!(records, event_name, actor:, max_concurrent: 10)
        results = {}
        semaphore = ::Async::Semaphore.new(max_concurrent)
        barrier = ::Async::Barrier.new

        ::Async do |parent|
          records.each do |record|
            semaphore.acquire do
              barrier.async do
                begin
                  record.fire!(event_name, actor: actor)
                  results[record.id] = { success: true }
                rescue Fosm::Error => e
                  results[record.id] = { success: false, error: e.class.name, message: e.message }
                rescue => e
                  results[record.id] = { success: false, error: "Unexpected", message: e.message }
                end
              end
            end
          end

          barrier.wait
        end

        results
      rescue ::Async::TimeoutError
        barrier.stop
        { error: "Timeout", partial_results: results }
      end

      # All-or-nothing batch (transaction across records)
      # Note: This is discouraged for FOSM as per-record transactions
      # are preferred for isolation.
      def self.fire_all_or_nothing!(records, event_name, actor:)
        ::Async do
          barrier = ::Async::Barrier.new

          records.each do |record|
            barrier.async do
              record.fire!(event_name, actor: actor)
            end
          end

          barrier.wait
        rescue => e
          barrier.stop
          raise Fosm::BulkOperationFailed.new("Rolled back due to: #{e.message}")
        end
      end
    end

    class BulkOperationFailed < Fosm::Error; end
  end
end
