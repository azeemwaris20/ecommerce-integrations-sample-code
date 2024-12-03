module Shops::Import::Quickbooks

  # Check if the QuickBooks token is active
  def quickbooks_token_active?
    begin
      quickbooks_service.query()
      true
    rescue Quickbooks::AuthorizationFailure
      false
    end
  end

  # Ensure that the QuickBooks token is active before making a query
  def ensure_token_active!
    refresh_token! unless quickbooks_token_active?
  end

  def quickbooks_price_converted
    currency != account.currency_code
  end

  def quickbooks_convert_amount(amount, date, conversion_note=nil)
    if quickbooks_price_converted
      exchanged_amount = CurrencyExchangeRate.exchange(amount, date, currency, account.currency_code)
      price_conversion_note << "#{conversion_note}: #{exchanged_amount[:conversion_note]}" if conversion_note
      exchanged_amount[:converted_amount]
    else
      BigDecimal(amount.to_s)
    end
  end

  def quickbooks_inventory_assets
    ensure_token_active!
    quickbooks_service.query("Select * From Account where AccountType = 'Other Current Asset'", per_page: 1000).entries
  end

  def quickbooks_default_inventory_asset
    ensure_token_active!
    quickbooks_service.query("Select * From Account where AccountType = 'Other Current Asset' AND Name = 'Inventory Asset'", per_page: 1000).entries.first
  end

  def quickbooks_cogs
    ensure_token_active!
    quickbooks_service.query("Select * From Account where AccountType = 'Cost of Goods Sold'", per_page: 1000).entries
  end

  def quickbooks_default_cogs
    ensure_token_active!
    quickbooks_service.query("Select * From Account where AccountType = 'Cost of Goods Sold' AND Name = 'Cost of Goods Sold'", per_page: 1000).entries.first
  end

  def quickbooks_service(service = Quickbooks::Service::Account.new)
    service.company_id = shop.authentication.uid
    service.access_token = oauth_access_token
    service
  end

  def oauth_client
    options = {
      site: "https://appcenter.intuit.com/connect/oauth2",
      authorize_url: "https://appcenter.intuit.com/connect/oauth2",
      token_url: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"
    }
    OAuth2::Client.new(ENV['xxx'], ENV['xxx'], options)
  end

  def oauth_access_token
    OAuth2::AccessToken.new(oauth_client, shop.authentication.token, refresh_token: shop.authentication.refresh_token)
  end

  def refresh_token!
    t = oauth_access_token
    refreshed = t.refresh!
    shop.authentication.update!(token: refreshed.token, refresh_token: refreshed.refresh_token)
  end

end
