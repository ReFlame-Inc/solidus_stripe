# frozen_string_literal: true

module SolidusStripe
  # Stripe's ordinary gateway path does not mark its source reusable. Use the
  # server's successful confirmation receipt without making another API call
  # after payment, and leave Solidus's other payment sources to the base service.
  class AddPaymentSourcesToWallet < Spree::Wallet::AddPaymentSourcesToWallet
    def add_to_wallet
      super
      # This transition hook runs before finalize sets completed_at.
      return unless order.state == "complete" && order.user && !order.temporary_payment_source

      sources = order.payments.where(state: %w[pending completed processing]).filter_map do |payment|
        next unless payment.source.is_a?(SolidusStripe::PaymentSource)
        next unless saved_for_customer?(payment)

        payment.source
      end.uniq
      return if sources.empty?

      wallet_sources = sources.sort_by(&:id).map { |source| order.user.wallet.add(source) }
      order.user.wallet.default_wallet_payment_source = wallet_sources.last
    end

    private

    def saved_for_customer?(payment)
      customer = SolidusStripe::Customer.find_by(payment_method: payment.payment_method, source: order.user)
      return false if customer&.stripe_id.blank?

      payment.log_entries.order(id: :desc).any? do |entry|
        response = entry.parsed_details
        next false unless response.is_a?(ActiveMerchant::Billing::Response) && response.success?

        intent = JSON.parse(response.params.fetch("data", "null"))
        intent.is_a?(Hash) &&
          intent.dig("metadata", "solidus_temporary_source") != "true" &&
          intent["id"] == payment.response_code &&
          intent["payment_method"] == payment.source.stripe_payment_method_id &&
          intent["customer"] == customer.stripe_id &&
          %w[on_session off_session].include?(intent["setup_future_usage"]) &&
          %w[requires_capture succeeded processing].include?(intent["status"])
      rescue JSON::ParserError
        false
      end
    end
  end
end
