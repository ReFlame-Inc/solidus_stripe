# frozen_string_literal: true

module SolidusStripe
  class PaymentIntent < ApplicationRecord
    belongs_to :order, class_name: 'Spree::Order'
    belongs_to :payment_method, class_name: 'SolidusStripe::PaymentMethod'

    def self.current_payment(order)
      order.payments.where.not(state: %w[invalid void]).reorder(id: :desc).first
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
      stripe_intent.amount == stripe_order_amount
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
      locked_order.with_lock do
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
          order.complete!
          return true
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
          order.complete!
        else
          order.payment_failed!
        end

        successful
      end
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
