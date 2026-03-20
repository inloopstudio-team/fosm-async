# frozen_string_literal: true

module Fosm
  module Async
    # Mixin for fiber-based async transition processing.
    # Include this alongside Fosm::Lifecycle for high-throughput scenarios.
    #
    # Example:
    #   class Invoice < ApplicationRecord
    #     include Fosm::Lifecycle
    #     include Fosm::Async::LifecycleAsync
    #   end
    #
    #   # Process 100 invoices concurrently with 1 thread
    #   Async do
    #     invoices.each do |inv|
    #       Async { inv.fire_async!(:send, actor: user) }
    #     end
    #   end
    #
    module LifecycleAsync
      extend ActiveSupport::Concern

      # Fire transition inside a fiber that yields during I/O operations.
      # Side effects that hit I/O (HTTP calls, DB writes) automatically yield,
      # allowing other transitions to proceed.
      def fire_async!(event_name, actor: nil, metadata: {})
        Async do
          # Pre-flight checks (same validation as fire!)
          lifecycle = self.class.fosm_lifecycle
          raise Fosm::Error, "No lifecycle defined" unless lifecycle

          event_def = lifecycle.find_event(event_name)
          raise Fosm::UnknownEvent.new(event_name, self.class) unless event_def

          current = self.state.to_s
          current_state_def = lifecycle.find_state(current)

          if current_state_def&.terminal? && !event_def.force?
            raise Fosm::TerminalState.new(current, self.class)
          end

          unless event_def.valid_from?(current)
            raise Fosm::InvalidTransition.new(event_name, current, self.class)
          end

          # Run guards concurrently (they can yield during I/O)
          GuardRunner.evaluate_concurrently(event_def.guards, self)

          # RBAC check
          if lifecycle.access_defined?
            fosm_enforce_event_access!(event_name, actor)
          end

          # Execute transition with fiber-aware transaction handling
          from_state = current
          to_state = event_def.to_state.to_s
          transition_data = { from: from_state, to: to_state, event: event_name.to_s, actor: actor }

          result = nil
          ActiveRecord::Base.connection_pool.with_connection do
            ActiveRecord::Base.transaction do
              update!(state: to_state)

              if Fosm.config.transition_log_strategy == :sync
                Fosm::TransitionLog.create!(build_log_data(event_name, actor, metadata))
              end

              # Run side effects — they can yield during I/O
              event_def.side_effects.each do |side_effect_def|
                side_effect_def.call(self, transition_data)
              end
            end
          end

          # Async/buffered logging
          log_data = build_log_data(event_name, actor, metadata)
          case Fosm.config.transition_log_strategy
          when :async
            Fosm::TransitionLogJob.perform_later(log_data)
          when :buffered
            TransitionBufferFiber.push(log_data)
          end

          # Webhook delivery (fire-and-forget in fiber)
          Async do
            Fosm::WebhookDeliveryJob.perform_later(
              record_type: self.class.name,
              record_id: self.id.to_s,
              event_name: event_name.to_s,
              from_state: from_state,
              to_state: to_state,
              metadata: metadata
            )
          end

          { success: true, state: to_state }

        rescue Fosm::Error => e
          { success: false, error: e.class.name, message: e.message }
        rescue => e
          { success: false, error: "Unexpected", message: e.message }
        end.wait
      end

      private

      def build_log_data(event_name, actor, metadata)
        {
          "record_type" => self.class.name,
          "record_id" => self.id.to_s,
          "event_name" => event_name.to_s,
          "from_state" => self.state.to_s,
          "to_state" => event_name.to_s,
          "actor_type" => actor_type_for(actor),
          "actor_id" => actor_id_for(actor),
          "actor_label" => actor_label_for(actor),
          "metadata" => metadata
        }
      end

      def actor_type_for(actor)
        return nil if actor.nil?
        return "symbol" if actor.is_a?(Symbol)
        actor.class.name
      end

      def actor_id_for(actor)
        return nil if actor.nil? || actor.is_a?(Symbol)
        actor.respond_to?(:id) ? actor.id.to_s : nil
      end

      def actor_label_for(actor)
        return actor.to_s if actor.is_a?(Symbol)
        return nil unless actor
        actor.respond_to?(:email) ? actor.email : actor.to_s
      end
    end
  end
end
