module Shops::Import::SquarespaceShop
  # API Docs
  #https://developers.squarespace.com/commerce-apis/overview

  include Shops::Import::SquarespaceShop::Orders
  include Shops::Import::SquarespaceShop::Products

  # @return [Boolean] The shop token is currently active
  def squarespace_token_active?
    squarespace_client.website
    true
  rescue SquarespaceApi::Errors::Unauthorized => e
    return false unless refresh
    retry
  end

  def squarespace_website
    @squarespace_website ||= squarespace_client.website
  rescue SquarespaceApi::Errors::Unauthorized
    refresh
    retry
  end

  # @return [Boolean] If the currency needs been converted when importing
  def squarespace_price_converted
    squarespace_currency != account.currency_code
  end

  # Converts the amount into the accounts currency on the date provided
  # @return [BigDecimal] the converted or original amount
  def squarespace_convert_amount(amount, date, conversion_note = nil)
    if squarespace_price_converted
      exchanged_amount = CurrencyExchangeRate.exchange(amount, date, squarespace_currency, account.currency_code)
      if conversion_note
        price_conversion_note << "#{conversion_note}: #{exchanged_amount[:conversion_note]}"
      end
      exchanged_amount[:converted_amount]
    else
      BigDecimal(amount.to_s || 0)
    end
  end

  def squarespace_currency
    @squarespace_currency ||= squarespace_website["currency"]
  end
  
  def squarespace_start_date
    date_from.beginning_of_day.utc.iso8601
  end

  def squarespace_end_date
    date_to.end_of_day.utc.iso8601
  end

  def squarespace_client
    @squarespace_client = SquarespaceApi::Client.new(
      SquarespaceApi::Config.new(
        access_token: shop.token
      )
    )
  end

  def squarespace_api_available?
    squarespace_token_active?
  end

  def squarespace_product(product_id)
    squarespace_client.products.find_by_ids([product_id]).first
  rescue SquarespaceApi::Errors::NotFound
    nil
  rescue SquarespaceApi::Errors::Unauthorized
    refresh
    retry
  end

  def squarespace_order(order_id)
    squarespace_client.orders.find(order_id)
  rescue SquarespaceApi::Errors::Unauthorized
    refresh
    retry
  end

  def squarespace_products
    products = []
    squarespace_client.products.all(modifiedAfter: squarespace_start_date, modifiedBefore: squarespace_end_date) do |products_per_page|
      products += products_per_page
      sleep 5
    end

    products
  rescue SquarespaceApi::Errors::Unauthorized
    refresh
    retry
  end

  def squarespace_transactions
    squarespace_client.transactions.all
  rescue SquarespaceApi::Errors::Unauthorized
    refresh
    retry
  end

  def squarespace_orders
    orders = []
    squarespace_client.orders.all(modifiedAfter: squarespace_start_date, modifiedBefore: squarespace_end_date) do |orders_per_page|
      orders += orders_per_page
      sleep 5
    end

    orders
  rescue SquarespaceApi::Errors::Unauthorized
    refresh
    retry
  end

  def refresh
    refresh_token if expired?
  rescue
    return false
  end

  def expired?
    return true if shop.authentication.token_expires_at.blank?
    Time.now + 10.minutes >= Time.at(shop.authentication.token_expires_at)
  end

  def refresh_token
    tokens = squarespace_client.tokens.create(
      refresh_token: shop.authentication.refresh_token,
      grant_type: "refresh_token"
    )
    shop.authentication.token = tokens["token"]
    shop.authentication.token_expires_at = Time.at(tokens["access_token_expires_at"]).to_datetime
    shop.authentication.refresh_token = tokens["refresh_token"]
    shop.authentication.refresh_token_expires_at = Time.at(tokens["refresh_token_expires_at"]).to_datetime
    shop.authentication.save
  end
end
