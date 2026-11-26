# frozen_string_literal: true

module SolidusStripe
  class PaymentIntent < ApplicationRecord
    belongs_to :order, class_name: 'Spree::Order'
    belongs_to :payment_method, class_name: 'SolidusStripe::PaymentMethod'

    def self.current_payment(order)
      order.payments.where.not(state: %w[invalid void]).reorder(id: :desc).first
    end

    def self.pending_authentication_for(order:, payment_method:)
      return if order.has_checkout_step?("confirm")

      payment = current_payment(order)
      return unless payment&.payment_method_id == payment_method.id && payment.response_code.present?

      intent = find_by(order: order, payment_method: payment_method, stripe_intent_id: payment.response_code)
      return unless intent

      remote = intent.stripe_intent
      return unless remote.status == "requires_action" &&
        remote.amount == intent.stripe_order_amount &&
        remote.currency == order.currency.downcase

      intent
    rescue Stripe::StripeError => e
      Rails.logger.warn("[SolidusStripe] Failed to retrieve PaymentIntent #{intent&.stripe_intent_id}: #{e.message}")
      nil
    end

    def self.prepare_for_payment(payment, **stripe_creation_options)
      # Find or create the intent for the payment.
      intent = retrieve_for_payment(payment) || create_for_payment(payment, **stripe_creation_options)

      # Attach the payment intent to the payment.
      payment.update!(response_code: intent.stripe_intent.id)

      intent
    end

    def self.create_for_payment(payment, **stripe_intent_options)
      new(payment_method: payment.payment_method, order: payment.order)
        .tap { _1.update!(stripe_intent_id: _1.create_stripe_intent(payment, **stripe_intent_options).id) }
    end

    def self.retrieve_for_payment(payment)
      intent = where(payment_method: payment.payment_method, order: payment.order).last

      return unless intent&.usable?
      # Never share a PaymentIntent across two different Spree::Payment records,
      # otherwise webhooks and refund syncs can resolve the wrong payment.
      return if payment.order.payments
        .where(response_code: intent.stripe_intent_id)
        .where.not(id: payment.id)
        .exists?

      # Update the intent with the previously acquired payment method.
      intent.payment_method.gateway.request {
        Stripe::PaymentIntent.update(
          intent.stripe_intent_id,
          payment_method: payment.source.stripe_payment_method_id,
          payment_method_types: [payment.source.stripe_payment_method.type],
          metadata: { solidus_temporary_source: payment.order.temporary_payment_source ? "true" : "false" },
        )
      }

      intent
    end

    def usable?
      stripe_intent_id &&
      ['requires_payment_method', 'requires_confirmation'].include?(stripe_intent.status) &&
      stripe_intent.amount == stripe_order_amount &&
      (stripe_intent[:currency].nil? || stripe_intent[:currency] == order.currency.downcase)
    end

    def stripe_order_amount
      payment_method.gateway.to_stripe_amount(
        order.display_order_total_after_store_credit.money.fractional,
        order.currency,
      )
    end

    def process_payment
      locked_order = order
      remote = reload.stripe_intent
      insufficient_stock_error = nil

      result = locked_order.with_lock do
        return false unless order_id == locked_order.id

        self.order = locked_order
        payment = self.class.current_payment(locked_order)
        return false unless payment && payment.payment_method_id == payment_method_id &&
          payment.response_code == remote.id

        return false unless remote.amount == stripe_order_amount &&
          remote.currency == order.currency.downcase

        return %w[succeeded requires_capture processing].include?(remote.status) if order.completed?
        return false unless order.confirm? || (order.payment? && !order.has_checkout_step?("confirm"))

        # A settlement webhook may complete this payment while Stripe is being queried.
        if payment.completed?
          begin
            order.complete!
            return true
          rescue Spree::Order::InsufficientStock => e
            insufficient_stock_error = e
            Rails.logger.error("[SolidusStripe] Order #{order.number} could not complete after PaymentIntent #{remote.id} succeeded: #{e.message}")
            return false
          end
        end

        # A server-side attempt needing 3DS is marked failed by Solidus. The
        # authenticated return can retry only this order's matching payment.
        payment.update!(state: 'checkout') if payment.failed?
        payment.started_processing!

        case remote.status
        when 'processing'
          successful = true
        when 'requires_capture'
          payment.pend! unless payment.pending?
          successful = true
        when 'succeeded'
          payment.complete! unless payment.completed?
          successful = true
        else
          payment.failure!
          successful = false
        end

        SolidusStripe::LogEntries.payment_log(
          payment,
          success: successful,
          message: I18n.t("solidus_stripe.intent_status.#{remote.status}"),
          data: remote,
        )

        if successful
          begin
            order.complete!
          rescue Spree::Order::InsufficientStock => e
            # Preserve the authorized/captured payment state in Solidus so the
            # merchant can see the paid/authorized attempt and refund or fulfill.
            insufficient_stock_error = e
            Rails.logger.error("[SolidusStripe] Order #{order.number} could not complete after PaymentIntent #{remote.id} (#{remote.status}): #{e.message}")
            SolidusStripe::LogEntries.payment_log(
              payment,
              success: false,
              message: "Order could not be completed due to insufficient stock after Stripe #{remote.status}",
              data: remote,
            )
            successful = false
          end
        else
          order.payment_failed!
        end

        successful
      end

      raise insufficient_stock_error if insufficient_stock_error

      result
    end

    def stripe_intent
      @stripe_intent ||= payment_method.gateway.request do
        Stripe::PaymentIntent.retrieve(stripe_intent_id)
      end
    end

    def reload(...)
      @stripe_intent = nil
      super
    end

    def create_stripe_intent(payment, **stripe_intent_options)
      stripe_customer_id = SolidusStripe::Customer.retrieve_or_create_stripe_customer_id(
        payment_method: payment_method,
        order: order
      )

      payment_method.gateway.request do
        Stripe::PaymentIntent.create({
          amount: stripe_order_amount,
          currency: order.currency,
          capture_method: payment_method.auto_capture? ? 'automatic' : 'manual',
          setup_future_usage: payment_method.preferred_setup_future_usage.presence,
          customer: stripe_customer_id,
          payment_method: payment.source.stripe_payment_method_id,
          payment_method_types: [payment.source.stripe_payment_method.type],
          metadata: { solidus_order_number: order.number }.tap { |metadata|
            metadata[:solidus_temporary_source] = "true" if payment.order.temporary_payment_source
          },
          **stripe_intent_options,
        })
      end
    end
  end
end
