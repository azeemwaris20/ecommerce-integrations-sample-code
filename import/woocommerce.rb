module Shops::Import::Woocommerce
  include Shops::Import::Woocommerce::Orders
  include Shops::Import::Woocommerce::Products

  class AuthError            < StandardError; end
  class InvalidRequestError  < StandardError; end
  class NotFoundError        < StandardError; end
  class InvalidToken         < StandardError; end
  class TooManyRequestsError < StandardError; end
  class Error                < StandardError; end

  # @return [Boolean] The shop token is currently active
  def woocommerce_token_active?
    response = woocommerce_client.get("system_status")
    woocommerce_raise_response_exception(response.code, response.message) unless response.code == 200  
    true
  rescue => e
    Rollbar.error(e)

    # Don't Disable WooCommerce Shops
    true
  end

  # @return [WooCommerceAPI::Shop] The shop connected to the API calls
  def woocommerce_shop
    @woocommerce_shop ||= woocommerce_client.get("system_status").parsed_response
  end

  # @return [Boolean] If the currency needs been converted when importing
  def woocommerce_price_converted
    woocommerce_shop['settings']['currency'] != account.currency_code
  end

  # Converts the amount into the accounts currency on the date provided
  #
  # @return [BigDecimal] the converted or original amount
  def woocommerce_convert_amount(amount, date, conversion_note=nil)
    if woocommerce_price_converted
      exchaned_amount = CurrencyExchangeRate.exchange(amount, date, woocommerce_shop['settings']['currency'], account.currency_code)
      price_conversion_note << "#{conversion_note}: #{exchaned_amount[:conversion_note]}" if conversion_note
      exchaned_amount[:converted_amount]
    else
      BigDecimal(amount.blank? ? 0 : amount.to_s)
    end
  end

  # @return [WooCommerce::API] The WooCommerce client connected to the API calls
  def woocommerce_client
    @woocommerce_client ||= WooCommerce::API.new(
      shop.authentication.uid,
      shop.token,
      shop.token_secret,
      {
        wp_api: true,
        version: "wc/v2",
        query_string_auth: true,
        verify_ssl: false
      }
    )
  end

  # Pings the WooCommerce shop to see if we can access it to run an import
  # @return [Boolean] Indicating WooCommerce is available
  def woocommerce_api_available?
    begin
      system_status = woocommerce_client.get("system_status")

      # Check that we can access the WooCommerce feed
      unless system_status.code == 200
        external_import.update({ failed_at: DateTime.now, error_messages: { message: system_status.body } }) if external_import
        return false
      end

      # Check that we support the WooCommerce shop currency
      unless Currency.is_supported?(woocommerce_shop['settings'].try(:[], 'currency'))
        external_import.update({ failed_at: DateTime.now, error_messages: { message: 'Shop currency not supported' } }) if external_import
        return false
      end

      true

    rescue => e
      external_import.update({ failed_at: DateTime.now, error_messages: { message: e.message, backtrace: e.backtrace.map {|l| "  #{l}\n"}.join } }) if external_import
      false
    end
  end

  def woocommerce_get(endpoint)
    Retryable.retryable(tries: 5, sleep: lambda { |n| 3**n }) do |retries, exception|
      log "Woocommerce.get(#{endpoint}). Retries: #{retries}"
      woocommerce_client.get(endpoint).parsed_response
    end
  end

  # @return [Hash] A instance of a WooCommerce::Variation
  def woocommerce_variation(product_id, variation_id)
    endpoint = "products/#{product_id}/variations/#{variation_id}"
    woocommerce_get(endpoint)
  end

  # @return [Hash] A instance of a WooCommerce::Product
  def woocommerce_product(product_id)
    endpoint = "products/#{product_id}"
    woocommerce_get(endpoint)
  end
  alias :woocommerce_listing :woocommerce_product

  # @return [Hash] A instance of a WooCommerce::Order
  def woocommerce_order(order_id)
    endpoint = "orders/#{order_id}"
    woocommerce_get(endpoint)
  end

  # @return [Array] An array of WooCommerce::Products
  def woocommerce_products(page=1)
    params = { per_page: 50, page: page }
    # Import all listings - switch this on when we want to make this faster
    # params.merge!({ after: external_import.params[:date_from].to_time.utc.iso8601, before: external_import.params[:date_to].end_of_day.to_time.utc.iso8601 }) if external_import

    response = Retryable.retryable(tries: 5, sleep: lambda { |n| 3**n }) do |retries, exception|
      log "Woocommerce.get('products', #{params}). Retries: #{retries}"
      woocommerce_client.get("products", params)
    end
    
    woocommerce_raise_response_exception(response.code, response.message) unless response.code == 200  
    
    external_import.update_attribute(:total_items, response.headers["x-wp-total"] || 0) if external_import
    response
  end

  # @return [Array] An array of WooCommerce::Orders
  def woocommerce_orders(page=1)
    params = { per_page: 50, page: page }
    params.merge!({ after: date_from.to_time.utc.iso8601, before: end_date.to_time.utc.iso8601 }) if external_import
    params.merge!({ include: external_import.params[:order_ids] }) if external_import.try(:params).try{ |p| p[:order_ids] }

    response = Retryable.retryable(tries: 5, sleep: lambda { |n| 3**n }) do |retries, exception|
      log "Woocommerce.get('orders', #{params}). Retries: #{retries}"
      woocommerce_client.get("orders", params)
    end

    woocommerce_raise_response_exception(response.code, response.message) unless response.code == 200

    external_import.update_attribute(:total_items, response.headers["x-wp-total"] || 0) if external_import
    response
  end

  # @return [Array] An array of WooCommerce::Refunds
  def woocommerce_order_refunds(order_id)
    endpoint = "orders/#{order_id}/refunds"
    woocommerce_get(endpoint)
  end

  def log_error(error_type, message)
    Rails.logger.error("Shops::Import::Woocommerce::#{error_type}: #{message}")
  end

  private

  def woocommerce_raise_response_exception(code, message)
    parameters = "account_id: #{account.id}, shop_id: #{shop.id}"
    error = "Error: #{message}; Parameters: #{parameters}"

    case code
    when 401
      raise self.class::AuthError.new(error)
    when 404
      raise self.class::NotFoundError.new(error)
    when 429
      raise self.class::TooManyRequestsError.new(error)
    end
  end
end
