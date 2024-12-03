module Shops::Import::PaypalShop
  include Shops::Import::PaypalShop::Invoices

  # @return [Boolean] The shop token is currently active
  def paypal_token_active?
    # Return true as there is no way to test this in PayPal
    true
  end

  # Determines if prices require currency conversion
  #
  # @return [Boolean]
  def paypal_price_converted
    currency != account.currency_code
  end

  # Use the external_import if provided otherwise set the start time of 2005-1-1
  #
  # @return [DateTime] The invoice search start time
  def paypal_begin_time
    start_date || DateTime.new(2005,1,1)
  end

  # Use the external_import if provided otherwise set the start time of 2005-1-1
  #
  # @return [DateTime] The invoice search end time
  def paypal_end_time
    end_date || DateTime.now
  end

  # Converts the amount into the account currency on the date occured
  #
  # @return [BigDecimal] converted or original amount
  def paypal_convert_amount(amount, date, conversion_note=nil)
    if price_converted
      exchaned_amount = CurrencyExchangeRate.exchange(amount, date, currency, account.currency_code)
      price_conversion_note << "#{conversion_note}: #{exchaned_amount[:conversion_note]}" if conversion_note
      exchaned_amount[:converted_amount]
    else
      BigDecimal(amount.to_s)
    end
  end

  # Find or create a Contact from the PayPal customer
  #
  # @param [PayPal::SDK::Invoice::DataTypes::BusinessInfoType] contact the contact details from the invoice
  # @return [Contact]
  def contact_from_paypal_customer(billing_info)
    name = billing_info.name.try(:full_name) || ""
    if billing_info.email_address.blank? || billing_info.email_address == "noreply@here.paypal.com"
      account.contacts.with_contact_type(:customer).create(name: name, external_reference_type: :paypal) if name.present?
    else
      account.contacts.with_contact_type(:customer).where(email: billing_info.email_address).first_or_create(name: name, external_reference_type: :paypal)
    end
  end

  # @return [String] A new access token for the PayPal Rest client
  def paypal_access_token
    @paypal_access_token ||= refresh_paypal_token
  end

  # @return [String] A new access token for the PayPal Rest client
  def refresh_paypal_token
    # Renew the token if expired
    if shop.authentication.token_expired?
      params = {
        grant_type: 'refresh_token',
        refresh_token: shop.authentication.refresh_token,
        client_id: ENV['xxx'],
        client_secret: ENV['xxx']
      }

      response = case ENV['xxx']
        when 'sandbox'
          Faraday.post("https://api.sandbox.paypal.com/v1/identity/openidconnect/tokenservice", params)
        when 'live'
          Faraday.post("https://api.paypal.com/v1/identity/openidconnect/tokenservice", params)
      end
      response_hash = JSON.parse(response.body)

      shop.authentication.update({
        token: response_hash['access_token'],
        token_expires_at: DateTime.now + response_hash["expires_in"].to_i.seconds
      })

    end
    # Get the latest emails associated with PayPal to filter out inbound invoices
    userinfo = Paypal::Rest::Client.new(shop.token, paypal_sandbox?).userinfo
    shop.update_attribute(:paypal_emails, userinfo[:emails].map(&:value))

    shop.token
  end

  # @return [Paypal::Rest::Client] The PayPal Rest client for the request
  def paypal_client
    @paypal_client ||= Paypal::Rest::Client.new(paypal_access_token, paypal_sandbox?)
  end

  # @return [Boolean] PayPal sandbox mode
  def paypal_sandbox?
    ENV['xxx'] == 'sandbox'
  end
end
