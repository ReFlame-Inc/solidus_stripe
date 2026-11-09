# frozen_string_literal: true

module SolidusStripe::OrderPaymentFailure
  # Solidus normally returns from confirm to payment after a failed attempt.
  # With confirm removed, a Stripe challenge must keep the order at payment.
  def payment_failed!(*args)
    if payment? && !has_checkout_step?("confirm") &&
        SolidusStripe::PaymentIntent.current_payment(self)&.payment_method.is_a?(SolidusStripe::PaymentMethod)
      true
    else
      super
    end
  end
end
