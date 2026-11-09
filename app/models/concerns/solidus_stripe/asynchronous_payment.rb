# frozen_string_literal: true

module SolidusStripe::AsynchronousPayment
  def purchase!
    catch(:solidus_stripe_processing) { super }
  end

  def authorize!
    catch(:solidus_stripe_processing) { super }
  end

  private

  def handle_response(response)
    accepted = super
    # Solidus has already entered processing and recorded the gateway receipt.
    # Leave settlement (including the final state change) to the webhook.
    if accepted && payment_method.is_a?(SolidusStripe::PaymentMethod) && response.params["solidus_stripe_processing"]
      throw :solidus_stripe_processing, true
    end
    accepted
  end
end
