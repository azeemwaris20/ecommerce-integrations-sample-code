module Shops::Import::SquareShop
  include Shops::Import::SquareShop::Items
  include Shops::Import::SquareShop::Orders

  # @return [Boolean] The shop token is currently active
  def square_token_active?
    square_client.locations.list_locations.success?
  end

  # @return [Boolean] Prices require currency conversion
  def square_price_converted
    square_shop[:currency] != account.currency_code
  end

  # Converts the amount into the account currency on the date occured
  #
  # @return [BigDecimal] converted or original amount
  def square_convert_amount(amount, date, conversion_note=nil)
    if price_converted
      exchaned_amount = CurrencyExchangeRate.exchange(amount, date, square_shop[:currency], account.currency_code)
      price_conversion_note << "#{conversion_note}: #{exchaned_amount[:conversion_note]}" if conversion_note
      exchaned_amount[:converted_amount]
    else
      BigDecimal(amount)
    end
  end

  # Once all the tokens have been migrated over to the new refresh token setup this should be able to be altered to a
  # refrsh token only.
  # @return [String] Access token for Square. Requests a new token if expired.
  def square_access_token
    # Add the refresh token if we don't have one
    if shop.authentication.refresh_token.blank?
      client = ::Square::Client.new(access_token: shop.authentication.token, environment: ENV['xxx'])
      params = {
        body: {
          client_id: ENV['xxx'],
          client_secret: ENV['xxx'],
          grant_type: "migration_token",
          migration_token: shop.authentication.token
        }
      }
      result = client.o_auth.obtain_token(params)
      shop.authentication.update({
        token: result.data["access_token"],
        token_expires_at: result.data["expires_at"],
        refresh_token: result.data["refresh_token"]
      }) if result.success?
    end

    # Renew the token if expired
    if shop.authentication.token_expired?
      client = ::Square::Client.new(access_token: shop.authentication.token, environment: ENV['xxx'])
      params = {
        body: {
          client_id: ENV['xxx'],
          client_secret: ENV['xxx'],
          grant_type: "refresh_token",
          refresh_token: shop.authentication.refresh_token
        }
      }
      result = client.o_auth.obtain_token(params)
      shop.authentication.update({
        token: result.data["access_token"],
        token_expires_at: result.data["expires_at"],
        refresh_token: result.data["refresh_token"]
      }) if result.success?
    end

    shop.token
  end

  # @return [String] The relevant value returned for the Square object from the API
  def square_object(object_id)
    hash = "shop:#{shop.id}:#{object_id}"
    return $redis.get(hash) if $redis.get(hash)

    catalog_object = square_catalog_object(object_id)
    return nil unless catalog_object
    value = case catalog_object[:type]
      when "CATEGORY"
        catalog_object[:category_data][:name]
      when "IMAGE"
        catalog_object[:image_data][:url]
      when "ITEM_OPTION"
        catalog_object[:item_option_data][:name]
      when "ITEM_OPTION_VAL"
        catalog_object[:item_option_value_data][:name]
    end

    $redis.multi do |multi|
      multi.set(hash, value)
      multi.expire(hash, 3601)
    end

    value
  end

  # @return [Hash] An instance of a Square object
  def square_catalog_object(object_id)
    square_client.catalog.retrieve_catalog_object(object_id: object_id).data.try(:object)
  end
  alias :square_listing :square_catalog_object

  # @return [Square::Order] Square order lookup
  def square_order(order_id)
    square_client.orders.retrieve_order(order_id: order_id).data.try(:order)
  end

  def square_orders(order_ids, location)
    body = {location_id: location, order_ids: order_ids}
    square_client.orders.batch_retrieve_orders(body: body).body.orders
  rescue
    return []
  end

  def square_payment(payment_id)
    square_client.payments.get_payment(payment_id: payment_id)
  end

  def square_start_date
    start_date
  end

  def square_end_date
    end_date
  end

  # @return [Hash] Square merchant
  def square_shop
    @square_shop ||= square_client.locations.list_locations.data.locations[0]
  end

  # @return [Array] Square locations
  def square_locations
    @square_locations ||= square_client.locations.list_locations.data.locations.map{ |h| h[:id] }
  end

  # @return [Contact] Square contact for the account
  def square_contact
    @square_contact ||= Contact.find_or_create_default_square_contact(account)
  end

  # @return [SquareConnect::ApiClient] The SquareConnect API client to access the API calls
  def square_client
    @square_client ||= ::Square::Client.new(access_token: square_access_token, environment: ENV['xxx'])
  end
end
