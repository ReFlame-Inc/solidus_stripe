# frozen_string_literal: true
require 'solidus_stripe_spec_helper'

RSpec.describe SolidusStripe::Gateway do
  [:authorize, :purchase].each do |operation|
    %w[requires_action requires_payment_method processing requires_capture succeeded].each do |status|
      it "reports #{operation} honestly for Stripe status #{status}" do
        method = create(:solidus_stripe_payment_method)
        order = create(:solidus_stripe_order, amount: 10, payment_method: method)
        payment = order.payments.last
        created = Stripe::PaymentIntent.construct_from(id: 'pi_regression', status: 'requires_confirmation')
        confirmed = Stripe::PaymentIntent.construct_from(id: created.id, status: status)
        allow(Stripe::Customer).to receive(:create).and_return(Stripe::Customer.construct_from(id: 'cus_test'))
        allow(payment.source).to receive(:stripe_payment_method).and_return(
          Stripe::PaymentMethod.construct_from(id: 'pm_test', type: 'card')
        )
        allow(Stripe::PaymentIntent).to receive(:create).and_return(created)
        allow(Stripe::PaymentIntent).to receive(:retrieve).and_return(created)
        allow(Stripe::PaymentIntent).to receive(:confirm).and_return(confirmed)

        response = method.gateway.public_send(operation, 1000, payment.source, originator: payment)
        expected_success = operation == :authorize ? %w[processing requires_capture succeeded].include?(status) : %w[processing succeeded].include?(status)
        expect(response.success?).to eq(expected_success)
        expect(JSON.parse(response.params.fetch('data')).fetch('status')).to eq(status)
      end
    end
  end
end
