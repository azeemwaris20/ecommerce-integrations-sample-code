module Shops::Import::EtsyShop
  include Shops::Import::EtsyShop::Orders
  include Shops::Import::EtsyShop::Products
  include Shops::Import::EtsyShop::Expenses

  # @return [Boolean] The shop token is currently active
  def etsy_token_active?
    etsy_shop
    true
  rescue
    false
  end

  # @return [::Etsy::V3::Response::Shop] The shop connected to the API calls
  def etsy_shop
    @etsy_shop ||= with_valid_token do 
      etsy_client.get_shop_by_owner_user_id(shop.authentication.uid) 
    end
  end

  # @return [Boolean] If the currency needs been converted when importing
  def etsy_price_converted(currency_code=nil)
    if currency_code.present?
      currency_code != account.currency_code
    else
      etsy_shop.currency_code != account.currency_code
    end
  end

  def etsy_currency_code(currency_code=nil)
    if currency_code.present?
      currency_code
    else
      etsy_shop.currency_code
    end
  end

  #Converts the amount into the accounts currency on the date provided
  #@return [BigDecimal] the converted or original amount
  def etsy_convert_amount(amount, date, conversion_note=nil, currency_code=nil)
    return BigDecimal(amount.to_s) unless etsy_price_converted(currency_code)
    date = Time.at(date) if date.is_a? Integer
    exchanged_amount = CurrencyExchangeRate.exchange(
      amount, date, etsy_currency_code(currency_code), account.currency_code
    )
    price_conversion_note << "#{conversion_note}: #{exchanged_amount[:conversion_note]}" if conversion_note
    BigDecimal(exchanged_amount[:converted_amount].to_s)
  end

  # @return [Etsy::V3::Client] The Etsy client connected to the API calls
  def etsy_client
    unless shop.authentication.refresh_token.present?
      response = Etsy::V3::Client.exchange_token(ENV['xxx'], shop.token)
      shop.authentication.provider_data = {} unless shop.authentication.provider_data
      shop.authentication.provider_data[:legacy_token] = shop.authentication.token
      shop.authentication.token = response.access_token
      shop.authentication.refresh_token = response.refresh_token
      shop.authentication.save
    end

    @etsy_client ||= Etsy::V3::Client.new(
      shop.token, ENV['xxx'],
      shop.authentication.uid
    )
  end

  # Pings the etsy shop to see if we can access it to run an import
  # @return [Boolean] Indicating etsy is available
  def etsy_api_available?
    with_valid_token { etsy_client.ping }
    true
  rescue
    false
  end

  def etsy_start_date
    start_date.to_i
  end

  def etsy_end_date
    end_date.to_i
  end

  def etsy_listing(listing_id)
    with_valid_token { etsy_client.get_listing(listing_id) }
  end

  def etsy_listings(offset, state)
    with_valid_token do
      etsy_client.get_listings_by_shop(etsy_shop.shop_id, offset, state)
    end
  end

  def etsy_listing_inventory(listing_id)
    with_valid_token { etsy_client.get_listing_inventory(listing_id) }
  end

  def etsy_listing_images(listing_id)
    with_valid_token do
      etsy_client.get_listing_images(etsy_shop.shop_id, listing_id)
    end
  end

  def get_etsy_receipt(receipt_id) # orders
    with_valid_token do
      etsy_client.get_shop_receipt(etsy_shop.shop_id, receipt_id)
    end
  end
  alias :etsy_order :get_etsy_receipt

  def etsy_receipts(opts) # orders
    with_valid_token { etsy_client.get_shop_receipts(opts) }
  end

  def get_etsy_transactions_by_receipt_id(receipt_id) # Orders line item
    with_valid_token do
      etsy_client.get_shop_receipt_transactions_by_receipt(
        etsy_shop.shop_id, 
        receipt_id
      )
    end
  end

  def etsy_payment(receipt_id)
    with_valid_token do
      etsy_client.get_shop_payment_by_receipt_id(etsy_shop.shop_id, receipt_id)
    end.results.first
  end

  # @return [::Etsy::V3::Response::Product] The Etsy Product for an Etsy Listing
  def etsy_product(listing_id, product_id)
    with_valid_token do
      etsy_client.get_listing_product(listing_id, product_id)
    end
  end

  def etsy_ledger_entries(offset, start_date, to_max)
    with_valid_token do
      etsy_client.get_shop_payment_account_ledger_entries(
        etsy_shop.shop_id,
        start_date,
        to_max,
        100,
        offset
      )
    end
  end

  def etsy_ledger_entry(ledger_entry_id)
    etsy_client.get_shop_payment_account_ledger_entry(
      etsy_shop.shop_id,
      ledger_entry_id
    )
  end

  def etsy_payments_by_ledger(ledger_entry_ids)
    with_valid_token do
      etsy_client.get_payment_account_ledger_entry_payments(
        etsy_shop.shop_id,
        ledger_entry_ids
      )
    end
  end

  private
  
  def with_valid_token(&block)
    block.call
  rescue Etsy::V3::Errors => e
    retried ||= false 
    if !retried && e.http_code == 401 && e.error == 'invalid_token'
      retried = true
      refresh_etsy_token
      retry      
    end
    raise e
  end

  def refresh_etsy_token
    response = etsy_client.refresh_token(
      ENV['xxx'],
      shop.authentication.refresh_token
    )

    shop.authentication.token = response.access_token
    shop.authentication.refresh_token = response.refresh_token
    shop.authentication.save
  end

  def etsy_ghost_product(order, line_item)
    log "Creating #{line_item.title} project for deleted product"
    account.projects.products.where({ name: line_item.title }).first_or_create(
      state: "active",
      base_unit_price: line_item.price.applied_amount,
      batch_quantity_type_id: account.quantity_types.find_by_name("item").id
    )
  end
end
