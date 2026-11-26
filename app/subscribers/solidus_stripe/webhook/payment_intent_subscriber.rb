# frozen_string_literal: true

require "solidus_stripe/refunds_synchronizer"

module SolidusStripe
  module Webhook
    # Handlers for Stripe payment_intent events.
    class PaymentIntentSubscriber
      include Omnes::Subscriber
      include SolidusStripe::MoneyToStripeAmountConverter

      handle :"stripe.payment_intent.succeeded", with: :capture_payment
      handle :"stripe.payment_intent.amount_capturable_updated", with: :authorize_payment
      handle :"stripe.payment_intent.payment_failed", with: :fail_payment
      handle :"stripe.payment_intent.canceled", with: :void_payment

      # Captures a payment.
      #
      # Marks a Solidus payment associated to a Stripe payment intent as
      # completed, adding a log entry about the event.
      #
      # In the case of a partial capture, it also synchronizes the refunds.
      #
      # @param event [SolidusStripe::Webhook::Event]
      # @see SolidusStripe::RefundsSynchronizer
      def capture_payment(event)
        payment = extract_payment_from_event(event)
        return false unless payment

        order = payment.order
        completed = order.with_lock do
          payment.reload
          if payment.completed?
            complete_awaiting_order(order, payment, event.data.object)
            break false
          end

          if payment.failed?
            break false unless recoverable_3ds_payment?(order, payment, event.data.object)

            payment.update!(state: "checkout")
            payment.started_processing!
          end

          complete_payment(payment, data: event.data.object)
          complete_awaiting_order(order, payment, event.data.object)
          true
        end

        completed && sync_refunds(event)
      end

      # Authorizes a payment after manual-capture 3DS authentication completes
      # asynchronously (e.g. customer closed browser before returning).
      #
      # @param event [SolidusStripe::Webhook::Event]
      def authorize_payment(event)
        payment = extract_payment_from_event(event)
        return false unless payment

        intent_object = event.data.object
        return false unless intent_object.status == "requires_capture"

        order = payment.order
        order.with_lock do
          payment.reload
          break false if payment.completed? || payment.void? || payment.invalid?

          if payment.pending?
            complete_awaiting_order(order, payment, intent_object)
            break true
          end

          if payment.failed?
            break false unless recoverable_3ds_payment?(order, payment, intent_object)

            payment.update!(state: "checkout")
            payment.started_processing!
          end

          payment.pend! unless payment.pending?
          SolidusStripe::LogEntries.payment_log(
            payment,
            success: true,
            message: "Authorization was successful after payment_intent.amount_capturable_updated webhook",
            data: intent_object
          )
          complete_awaiting_order(order, payment, intent_object)
          true
        end
      end

      # Fails a payment.
      #
      # Marks a Solidus payment associated to a Stripe payment intent as
      # failed, adding a log entry about the event.
      #
      # @param event [SolidusStripe::Webhook::Event]
      def fail_payment(event)
        payment = extract_payment_from_event(event)
        return unless payment

        payment.with_lock do
          break if payment.failed? || payment.completed? || payment.void? || payment.invalid?

          payment.failure!.tap do
            SolidusStripe::LogEntries.payment_log(
              payment,
              success: false,
              message: "Payment was marked as failed after payment_intent.failed webhook"
            )
          end
        end
      end

      # Voids a payment.
      #
      # Voids a Solidus payment associated to a Stripe payment intent, adding a
      # log entry about the event.
      #
      # @param event [SolidusStripe::Webhook::Event]
      def void_payment(event)
        payment = extract_payment_from_event(event)
        return unless payment

        reason = event.data.object.cancellation_reason

        payment.with_lock do
          break if payment.void? || payment.failed? || payment.invalid?

          payment.void!.tap do
            SolidusStripe::LogEntries.payment_log(
              payment,
              success: true,
              message: "Payment was voided after payment_intent.voided webhook (#{reason})"
            )
          end
        end
      end

      private

      def extract_payment_from_event(event)
        stripe_payment_intent_id = event.data.object.id
        scope = event.payment_method.payments.where(response_code: stripe_payment_intent_id)
        payment = scope.where.not(state: %w[invalid void]).reorder(id: :desc).first ||
                  scope.reorder(id: :desc).first
        unless payment
          Rails.logger.warn("[SolidusStripe] Ignoring #{event.type} for unknown PaymentIntent #{stripe_payment_intent_id}")
        end
        payment
      end

      def awaiting_checkout_completion?(order)
        !order.completed? && (
          order.confirm? || (order.payment? && !order.has_checkout_step?("confirm"))
        )
      end

      def intent_matches_order?(order, intent_object)
        expected_amount = to_stripe_amount(
          order.display_order_total_after_store_credit.money.fractional,
          order.currency
        )
        intent_object[:amount] == expected_amount &&
          intent_object[:currency] == order.currency.downcase
      end

      def recoverable_3ds_payment?(order, payment, intent_object)
        awaiting_checkout_completion?(order) &&
          SolidusStripe::PaymentIntent.current_payment(order)&.id == payment.id &&
          intent_matches_order?(order, intent_object)
      end

      def complete_awaiting_order(order, payment, intent_object)
        return unless awaiting_checkout_completion?(order)
        return unless SolidusStripe::PaymentIntent.current_payment(order)&.id == payment.id
        return unless intent_matches_order?(order, intent_object)

        order.complete!
      rescue Spree::Order::InsufficientStock => e
        Rails.logger.error("[SolidusStripe] Order #{order.number} could not complete from webhook for PaymentIntent #{intent_object.id}: #{e.message}")
        SolidusStripe::LogEntries.payment_log(
          payment,
          success: false,
          message: "Order could not be completed due to insufficient stock after Stripe webhook",
          data: intent_object
        )
      end

      def complete_payment(payment, data: nil)
        payment.complete!.tap do
          SolidusStripe::LogEntries.payment_log(
            payment,
            success: true,
            message: "Capture was successful after payment_intent.succeeded webhook",
            data: data
          )
        end
      end

      def sync_refunds(event)
        event.data.object.to_hash => {
          id: stripe_payment_intent_id,
          amount: stripe_amount,
          amount_received: stripe_amount_received,
          currency:
        }
        return if stripe_amount == stripe_amount_received

        payment_method = event.payment_method
        RefundsSynchronizer
          .new(payment_method)
          .call(stripe_payment_intent_id)
      end
    end
  end
end
