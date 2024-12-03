module Shops::Import::Shopify
  include Shops::Import::Shopify::Orders
  include Shops::Import::Shopify::Products
  include Shops::Import::Shopify::Charges
  class CustomSessionStorage
    include ShopifyAPI::Auth
    attr_reader :shop

    def initialize(shop)
      @shop = shop
    end

    def store_session(session)
      @session ||= session
    end

    def load_session
      ShopifyAPI::Auth::Session.new(
        shop: shop.authentication.uid,
        access_token: shop.authentication.token
      )
    end

    def delete_session(id)
      true
    end
  end

  # @return [Boolean] The shop token is currently active
  def shopify_token_active?
    # using .present? fails because of Sorbet (I think)
    shopify_shop != nil
  rescue ShopifyAPI::Errors::HttpResponseError => e
    # Not Found : Keep shop alive in any other case
    case e&.response&.code 
    when 404, 401
      false
    else
      true
    end
  rescue => e
    Rollbar.error(e,{custom:"in shopify_token_active?, Shop: #{shop.id}"})
    true
  end

  # @return [ShopifyAPI::Shop] The shop connected to the API calls
  def shopify_shop
    shopify_context
    @shopify_shop ||= OpenStruct.new(shopify_get("shop")["shop"])
  end

  # @return [Boolean] If the currency needs been converted when importing
  def shopify_price_converted(conversion_currency=nil)
    return (conversion_currency != account.currency_code) if conversion_currency
    shopify_shop.currency != account.currency_code
  end

  # Converts the amount into the accounts currency on the date provided
  #
  # @return [BigDecimal] the converted or original amount
  def shopify_convert_amount(amount, date, conversion_note=nil, conversion_currency=nil)
    if shopify_price_converted(conversion_currency)
      conversion_currency ||= shopify_shop.currency
      exchaned_amount = CurrencyExchangeRate.exchange(amount, date, conversion_currency, account.currency_code)
      price_conversion_note << "#{conversion_note}: #{exchaned_amount[:conversion_note]}" if conversion_note
      exchaned_amount[:converted_amount]
    else
      BigDecimal(amount)
    end
  end

  # @return [ShopifyAPI::Product] A instance of a ShopifyAPI::Product
  # Shopify is returning product ids that don't exist in the catalog so need
  # to handle this case and return a nil object
  def shopify_product(product_id)
    return nil unless product_id.present?

    shopify_context
    OpenStruct.new(shopify_get("products/#{product_id}")["product"])
  rescue
    nil
  end
  alias_method :get_shopify_product, :shopify_product
  alias_method :shopify_listing, :shopify_product

  def shopify_products(params)
    return nil unless params.present?

    shopify_context
    shopify_get("products", params)["products"]
  end
  alias_method :get_shopify_products, :shopify_products

  # @return [ShopifyAPI::Order] A instance of a ShopifyAPI::Order
  def shopify_order(order_id)
    return nil unless order_id.present?

    shopify_context
    OpenStruct.new(shopify_get("orders/#{order_id}")["order"])
  rescue
    nil
  end
  alias_method :get_shopify_order, :shopify_order

  def shopify_orders(params)
    return nil unless params.present?

    shopify_context
    shopify_get("orders", params)["orders"]
  end
  alias_method :get_shopify_orders, :shopify_orders

  def shopify_order_transaction(order_id)
    return nil unless order_id.present?

    shopify_context
    shopify_get("orders/#{order_id}/transactions")["transactions"]
  end

  # This will return a single variant
  def shopify_variant(variant_id)
    return nil unless variant_id.present?

    shopify_context
    shopify_get("variants/#{variant_id}")["variant"]
  end

  # This will return an array of variants
  def shopify_product_variants(product_id)
    return nil unless product_id.present?

    shopify_context
    shopify_get("products/#{product_id}/variants")["variants"]
  end

  # Pings the users shop to see if we can access it to run an import
  # @return [Boolean] Indicating shopify is available
  def shopify_api_available?
    shopify_shop != nil
  rescue => e
    external_import.update(shopify_import_error_attributes(e)) if external_import
    false
  end

  def shopify_import_error_attributes(e)
    {
      failed_at: DateTime.now,
      error_messages: {
        message: e.message,
        backtrace: e.backtrace.map {|l| "  #{l}\n"}.join
      }
    }
  end

  # Activate a ShopifyAPI session
  # @return [ShopifyAPI::Shop] The shop connected to the API calls
  def shopify_session
    @shopify_session ||= CustomSessionStorage.new(shop).load_session
  end

  def shopify_context
    @shopify_context ||= ShopifyAPI::Context.setup(
      api_key: ENV['xxx'],
      api_secret_key: ENV['xxx'],
      host: shop.authentication.uid,
      scope: ENV['xxx'],
      is_embedded: true, # Set to true if you are building an embedded app
      api_version: "2023-10", # The version of the API you would like to use
      is_private: false, # Set to true if you have an existing private app
    )
    @shopify_context
  end

  def shopify_client
    @shopify_client ||= ShopifyAPI::Clients::Rest::Admin.new(session: shopify_session)
  end

  def shopify_get(path, query=nil)
    # Remove session from query as it causes issues with caching
    query.except!(:session) if query.present? && query.key?(:session)
    request = shopify_client.get(path: path, query: query)
    @shopify_last_header = request.headers
    request.body
  end

  def shopify_limits
    limits = OpenStruct.new
    limits.used, limits.limit =
      @shopify_last_header["x-shopify-shop-api-call-limit"][0].split("/").map(&:to_i)

    limits
  end

  def shopify_start_date
    start_date
  end

  def shopify_end_date
    start_date
  end

  def shopify_last_header
    @shopify_last_header
  end
end
