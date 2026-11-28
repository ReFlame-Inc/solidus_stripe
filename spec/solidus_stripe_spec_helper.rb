# frozen_string_literal: true

require 'stripe'
require 'support/solidus_stripe/storefront'
require 'vcr'
require 'capybara/selenium/driver_specializations/chrome_driver'
require 'uri'

module Chrome158CdpStorageClearCompat
  def execute_cdp(cmd, params = {})
    super
  rescue Selenium::WebDriver::Error::InvalidArgumentError
    raise unless cmd == 'Storage.clearDataForOrigin' && params[:origin] == '*'

    execute_cdp('Network.clearBrowserCookies')
    if params[:storageTypes].to_s.include?('local_storage')
      entries = execute_cdp('Page.getNavigationHistory').fetch('entries', [])
      entries.filter_map { |entry| http_origin_for(entry['url']) }.uniq.each do |origin|
        execute_cdp('Storage.clearDataForOrigin', origin: origin, storageTypes: 'local_storage')
      end
    end
  end

  private

  def http_origin_for(url)
    uri = URI.parse(url.to_s)
    return unless %w[http https].include?(uri.scheme) && uri.host

    port_part = uri.port == uri.default_port ? '' : ":#{uri.port}"
    "#{uri.scheme}://#{uri.host}#{port_part}"
  rescue URI::InvalidURIError
    nil
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(Chrome158CdpStorageClearCompat)

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
