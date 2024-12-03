module Shops::Import::WixShop
  include Shops::Import::WixShop::Orders
  include Shops::Import::WixShop::Products

  WIX_PAID_STATUS = %w(PAID PARTIALLY_REFUNDED FULLY_REFUNDED)

  # @return [Boolean] The shop token is currently active
  def wix_token_active?
    begin
      wix_client.get_properties
    rescue StandardError
      false
    end
    true
  end

  # @return [Wix::V1::PropertiesObject] The shop connected to the API calls
  def wix_shop
    @wix_shop ||= wix_client.get_properties
  end

  # @return [Boolean] If the currency needs been converted when importing
  def wix_price_converted
    wix_shop.properties.payment_currency != account.currency_code
  end

  def wix_price_converted
    wix_shop.properties.payment_currency != account.currency_code
  end

  # Converts the amount into the accounts currency on the date provided
  # @return [BigDecimal] the converted or original amount
  def wix_convert_amount(amount, date, conversion_note = nil)
    if wix_price_converted
      exchaned_amount = CurrencyExchangeRate.exchange(amount, date, wix_shop.properties.payment_currency, account.currency_code)
      if conversion_note
        price_conversion_note << "#{conversion_note}: #{exchaned_amount[:conversion_note]}"
      end
      exchaned_amount[:converted_amount]
    else
      BigDecimal(amount.to_s.blank? ? 0 : amount.to_s)
    end
  end

  def wix_start_date
    date_from.beginning_of_day.to_i
  end

  def wix_end_date
    date_to.end_of_day.to_i
  end

  # @return [Project] Creates a ghost product from the Wix Line Item
  def wix_ghost_product(wix_order, wix_line_item)
    # Create a puppet project to hold the information of the deleted product
    item_price = BigDecimal(wix_line_item.total_price)
    item_price -= BigDecimal(wix_line_item.tax || 0) if wix_line_item.tax_included_in_price
    item_price /= BigDecimal(wix_line_item.quantity || 1)

    base_unit_price = wix_convert_amount(item_price, wix_order.date_created)
    log "Creating #{wix_line_item.name} project for missing product"
    product_attributes = {
      state: 'active',
      base_unit_price: base_unit_price,
      batch_quantity_type_id: account.quantity_types.find_by(name: 'item').id
    }
    account.projects.products.where({ name: wix_line_item.name }).first_or_create(product_attributes)
  end

  # @return [Wix::V1::Client] The Wix client connected to the API calls
  def wix_client
    begin
      @wix_client = Wix::V1::Client.new(shop.token)
      if shop.authentication.token_expires_at.past?
        response = @wix_client.refresh_access_token(ENV['xxx'], ENV['xxx'], shop.authentication.refresh_token)
        shop.authentication.update(token: response.access_token, refresh_token: response.refresh_token, token_expires_at: 5.minutes.from_now)
        @wix_client = Wix::V1::Client.new(shop.token)
      end
      @wix_client
    rescue Wix::V1::Errors => err
      if err.to_s.include?("invalid_refresh_token")
        shop.deactivate!
        raise "Invalid WIX shop id #{shop.id} refresh token!"
      end
    end
  end

  # Pings the wix shop to see if we can access it to run an import
  # @return [Boolean] Indicating wix is available
  def wix_api_available?
    wix_token_active?
  end

  # @return [::Wix::V1::Response::ProductObject] A instance of a ::Wix::V1::Response::ProductObject
  def wix_product(product_id)
    wix_client.get_product(product_id)
  rescue
    nil
  end

  # @return [::Wix::V1::Response::OrderObject] A instance of a ::Wix::V1::Response::OrderObject
  def wix_order(order_id)
    wix_client.get_order(order_id)
  end

  # @return [Array] An array of ::Wix::V1::Response::ProductObject
  def wix_products(items)
    wix_client.query_products(100, items)
  end

  # @return [Array] An array of ::Wix::V1::Response::Orders
  def wix_orders(start_date, end_date, query_created, items)
    wix_client.query_orders(start_date, end_date, query_created, 100, items)
  end
end
