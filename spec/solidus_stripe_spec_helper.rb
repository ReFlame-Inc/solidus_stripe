# frozen_string_literal: true

require 'stripe'
require 'support/solidus_stripe/storefront'
require 'vcr'

Dir["#{__dir__}/support/solidus_stripe/**/*.rb"].sort.each { |f| require f }

RSpec.configure do |config|
  # Stripe.js runs real HTTP in the browser and cannot use VCR cassettes.
  config.filter_run_excluding live_stripe: true unless ENV['SOLIDUS_STRIPE_LIVE_TESTS'] == '1'

  config.include SolidusStripe::Webhook::RequestHelper, type: :webhook_request
end

VCR.configure do |config|
  config.cassette_library_dir = "fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.ignore_localhost = true
  config.configure_rspec_metadata!
  config.filter_sensitive_data('<STRIPE_API_KEY>') { ENV['SOLIDUS_STRIPE_API_KEY'] }
  config.filter_sensitive_data('<STRIPE_PUBLISHABLE_KEY>') { ENV['SOLIDUS_STRIPE_PUBLISHABLE_KEY'] }

  config.register_request_matcher :stripe_uri do |request|
    request.uri =~ %r{^https://api\.stripe\.com/v1/payment_methods/pm_.*} ||
    request.uri =~ %r{^https://api\.stripe\.com/v1/payment_intents/pi_.*} ||
    request.uri =~ %r{^https://api\.stripe\.com/v1/(customers|payment_intents|refunds)}
  end

  config.default_cassette_options = {
    match_requests_on: [:method, :stripe_uri]
  }
end
