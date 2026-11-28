# frozen_string_literal: true

require 'stripe'

class SolidusStripe::IntentsController < Spree::BaseController
  include Spree::Core::ControllerHelpers::Order

  before_action :load_payment_method

  rescue_from Spree::Order::InsufficientStock, with: :handle_insufficient_stock
  rescue_from Stripe::StripeError, with: :handle_stripe_error

  def after_confirmation
    unless params[:payment_intent]
      return head :unprocessable_entity
    end

    if (completed_order = completed_order_for_intent(params[:payment_intent]))
      redirect_to_completed_order(completed_order)
      return
    end

    order = current_order(create_order_if_necessary: true)
    unless order.confirm? ||
        (order.payment? && !order.has_checkout_step?("confirm"))
      redirect_to main_app.checkout_state_path(order.state)
      return
    end

    intent = SolidusStripe::PaymentIntent.find_by!(
      payment_method: @payment_method,
      order: order,
      stripe_intent_id: params[:payment_intent],
    )

    if intent.process_payment
      redirect_to_completed_order(order)
    else
      stripe_error_message = intent.stripe_intent.try(:last_payment_error)&.try(:message).presence
      flash[:error] = stripe_error_message || t('spree.payment_processing_failed')
      redirect_to(main_app.checkout_state_path(:payment, stripe_authentication_failed: true))
    end
  end

  private

  def load_payment_method
    order = current_order
    @payment_method = if order
      order
        .available_payment_methods
        .merge(SolidusStripe::PaymentMethod.with_slug(params[:slug]))
        .first!
    else
      SolidusStripe::PaymentMethod.with_slug(params[:slug]).first!
    end
  end

  def completed_order_for_intent(stripe_intent_id)
    intent = SolidusStripe::PaymentIntent.includes(:order).find_by(
      payment_method: @payment_method,
      stripe_intent_id: stripe_intent_id,
    )
    order = intent&.order
    return unless order&.completed?

    authorized = if spree_current_user
      order.user_id == spree_current_user.id
    else
      cookies.signed[:guest_token].present? && order.guest_token == cookies.signed[:guest_token]
    end
    order if authorized
  end

  def redirect_to_completed_order(order)
    flash.notice = t('spree.order_processed_successfully')
    flash['order_completed'] = true

    redirect_to(
      spree_current_user ?
        main_app.order_path(order) :
        main_app.token_order_path(order, order.guest_token)
    )
  end

  def handle_insufficient_stock(exception)
    Rails.logger.error("[SolidusStripe] Insufficient stock during after_confirmation: #{exception.message}")
    flash[:error] = t('spree.insufficient_stock_for_order')
    redirect_to main_app.cart_path
  end

  def handle_stripe_error(exception)
    Rails.logger.error("[SolidusStripe] Stripe error during after_confirmation: #{exception.message}")
    flash[:error] = t('spree.payment_processing_failed')
    redirect_to(main_app.checkout_state_path(:payment, stripe_authentication_failed: true))
  end
end
