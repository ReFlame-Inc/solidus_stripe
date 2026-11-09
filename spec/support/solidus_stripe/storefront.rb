# frozen_string_literal: true

if File.exist?(File.expand_path('../../solidus_storefront_spec_helper.rb', __dir__))
  require 'solidus_storefront_spec_helper'
  StripeStorefrontCheckoutHelpers = SolidusStorefront::System::CheckoutHelpers
else
  require 'solidus_starter_frontend_spec_helper'
  StripeStorefrontCheckoutHelpers = SolidusStarterFrontend::System::CheckoutHelpers
end
