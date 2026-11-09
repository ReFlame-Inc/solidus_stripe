# frozen_string_literal: true

require 'solidus_stripe_spec_helper'

RSpec.describe 'Stripe wallet after ordinary checkout', type: :request do
  around do |example|
    original_flow = Spree::Order.checkout_flow
    Spree::Order.remove_checkout_step(:confirm)
    example.run
  ensure
    Spree::Order.checkout_flow(&original_flow)
  end

  let(:user) { create(:user) }
  let(:settings) { { future_usage: 'off_session', auto_capture: false } }
  let(:confirmed_fields) do
    { id: 'pi_wallet', status: 'requires_capture', setup_future_usage: settings.fetch(:future_usage).presence,
      customer: 'cus_wallet', payment_method: 'pm_wallet' }
  end
  let(:payment_method) do
    create(:solidus_stripe_payment_method, auto_capture: settings.fetch(:auto_capture),
      preferred_setup_future_usage: settings.fetch(:future_usage))
  end
  let(:order) { Spree::TestingSupport::OrderWalkthrough.up_to(:delivery, user: user) }

  before do
    payment_method
    order
    sign_in(user) if user
    get '/checkout/payment'
    allow(Stripe::Customer).to receive(:create).and_return(Stripe::Customer.construct_from(id: 'cus_wallet'))
    allow(Stripe::PaymentMethod).to receive(:retrieve).and_return(Stripe::PaymentMethod.construct_from(id: 'pm_wallet',
      type: 'card'))
    created = Stripe::PaymentIntent.construct_from(id: 'pi_wallet', status: 'requires_confirmation')
    allow(Stripe::PaymentIntent).to receive_messages(
      create: created, retrieve: created, confirm: Stripe::PaymentIntent.construct_from(confirmed_fields)
    )
  end

  def submit_checkout
    expect(response).to have_http_status(:ok)
    patch update_checkout_path(state: 'payment'), params: {
      order: { payments_attributes: [{ payment_method_id: payment_method.id,
                                       source_attributes: { stripe_payment_method_id: 'pm_wallet' } }] }
    }
  end

  ['', 'on_session', 'off_session'].each do |future_usage|
    context "when initializing Elements with future usage #{future_usage.inspect}" do
      let(:settings) { super().merge(future_usage: future_usage) }

      it 'keeps the browser and the server future-usage settings consistent' do
        node = Nokogiri::HTML(response.body).at_css('[data-solidus-stripe-payment-options-value]')
        options = JSON.parse(node['data-solidus-stripe-payment-options-value'])
        expect(options.fetch('elementsInitialization')['setupFutureUsage']).to eq(
          settings.fetch(:future_usage).presence
        )
        submit_checkout
        expect(Stripe::PaymentIntent).to have_received(:create).with(
          hash_including(setup_future_usage: settings.fetch(:future_usage).presence)
        )
        expect(order.reload).to be_completed
      end
    end
  end

  context 'while an asynchronous purchase awaits settlement' do
    let(:settings) { super().merge(auto_capture: true) }
    let(:confirmed_fields) { super().merge(status: 'processing') }

    it 'completes checkout once and leaves the payment processing on retry' do
      submit_checkout
      expect(order.reload).to be_completed
      payment = order.payments.last
      expect(payment).to be_processing
      payment.process!
      expect(payment.reload).to be_processing
      expect(payment.capture_events).to be_empty
      expect(Stripe::PaymentIntent).to have_received(:create).once
      expect(Stripe::PaymentIntent).to have_received(:confirm).once
    end
  end

  ['on_session', 'off_session'].each do |future_usage|
    context "with #{future_usage}" do
      let(:settings) { super().merge(future_usage: future_usage) }

      it 'saves the verified payment source exactly once when checkout completes' do
        submit_checkout
        expect(order.reload).to be_completed
        payment = order.payments.last
        expect(payment.state).to eq('pending')
        expect(user.wallet_payment_sources.reload.pluck(:payment_source_id)).to eq([payment.source_id])
        expect(user.wallet.default_wallet_payment_source.payment_source_id).to eq(payment.source_id)
        expect { order.add_payment_sources_to_wallet }.not_to change(Spree::WalletPaymentSource, :count)
      end
    end
  end

  context 'with automatic capture' do
    let(:settings) { super().merge(auto_capture: true) }
    let(:confirmed_fields) { super().merge(status: 'succeeded') }

    it 'also saves the successfully captured source' do
      submit_checkout
      expect(order.reload).to be_completed
      expect(order.payments.last.state).to eq('completed')
      expect(user.wallet_payment_sources.count).to eq(1)
    end
  end

  context 'without future usage' do
    let(:settings) { super().merge(future_usage: '') }

    it 'completes payment without saving the source' do
      submit_checkout
      expect(order.reload).to be_completed
      expect(user.wallet_payment_sources.reload).to be_empty
    end
  end

  context 'with a guest', :with_guest_session do
    let(:user) { nil }

    it 'completes payment without creating a wallet entry' do
      expect { submit_checkout }.not_to change(Spree::WalletPaymentSource, :count)
      expect(order.reload).to be_completed
    end
  end

  context 'when authorization fails' do
    let(:confirmed_fields) { super().merge(status: 'requires_payment_method') }

    it 'does not save a failed payment source' do
      submit_checkout
      expect(order.reload).not_to be_completed
      expect(order.payments.last.state).to eq('failed')
      expect(user.wallet_payment_sources.reload).to be_empty
    end
  end

  context 'when Stripe did not confirm future usage despite the preference' do
    let(:confirmed_fields) { super().merge(setup_future_usage: nil) }

    it 'uses the confirmed result rather than the current gateway preference' do
      submit_checkout
      expect(order.reload).to be_completed
      expect(user.wallet_payment_sources.reload).to be_empty
    end
  end

  context 'when the receipt belongs to another customer' do
    let(:confirmed_fields) { super().merge(customer: 'cus_other') }

    it 'does not save the source in this user wallet' do
      submit_checkout
      expect(order.reload).to be_completed
      expect(user.wallet_payment_sources.reload).to be_empty
    end
  end

  context 'when the receipt contains a different payment source' do
    let(:confirmed_fields) { super().merge(payment_method: 'pm_other') }

    it 'does not save an unverified source' do
      submit_checkout
      expect(order.reload).to be_completed
      expect(user.wallet_payment_sources.reload).to be_empty
    end
  end

  it 'respects the Solidus temporary-source opt-out' do
    submit_checkout
    expect(user.wallet_payment_sources.count).to eq(1)
    user.wallet_payment_sources.destroy_all
    order.reload.temporary_payment_source = true
    expect { order.add_payment_sources_to_wallet }.not_to change(Spree::WalletPaymentSource, :count)
  end
end
