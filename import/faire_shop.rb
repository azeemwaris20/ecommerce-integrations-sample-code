module Shops::Import::FaireShop
  # include Shops::Import::Shop::Items
  include Shops::Import::FaireShop::Orders
  include Shops::Import::FaireShop::Products

  # @return [Boolean] The shop token is currently active
  def faire_token_active?
    faire_brand.present?
  end

  # @return [Boolean] Prices require currency conversion
  def faire_price_converted
    faire_shop[:currency] != account.currency_code
  end

  def requires_price_conversion(currency_code)
    account.currency_code != currency_code
  end

  # Converts the amount into the account currency on the date occured
  #
  # @return [BigDecimal] converted or original amount
  def faire_convert_amount(amount, date, currency_code, conversion_note=nil)
    return BigDecimal(amount) unless requires_price_conversion(currency_code)

    exchaned_amount = EuropeanCentralBankRateConverter.exchange(amount, date, currency_code, account.currency_code)
    price_conversion_note << "#{conversion_note}: #{exchaned_amount[:conversion_note]}" if conversion_note
    exchaned_amount[:converted_amount]
  end

  # Once all the tokens have been migrated over to the new refresh token setup this should be able to be altered to a
  # refrsh token only.
  # @return [String] Access token for . Requests a new token if expired.
  def faire_access_token
    # Add the refresh token if we don't have one
    shop.token
  end

  def faire_order(order_id)
    faire_client.order(order_id)
  end

  # @return [Hash]  merchant
  def faire_shop
    @faire_shop ||= shop
  end

  # @return [Product] product
  def faire_product(product_id)
    @faire_product ||= faire_client.product(product_id)
  end

  def faire_external_import_id
    external_import.try(:id)
  end

  # @return [Connect::ApiClient] The Connect API client to access the API calls
  def faire_client
    @faire_client ||= Faire::V1::Client.new(faire_access_token, faire_external_import_id)
  end

  def faire_brand
    faire_client.brand
  end
end
