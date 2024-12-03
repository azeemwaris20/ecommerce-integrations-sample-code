# Abstract base class for Import. Provides some helper methods for
# the import
#
# @attr_reader [Shop] shop The shop running the import
# @attr_writer [ExternalImport] external_import The external import for the shop
class Shops::Import
  include Shops::Import::Amazon
  include Shops::Import::EtsyShop
  include Shops::Import::PaypalShop
  include Shops::Import::Shopify
  include Shops::Import::SquareShop
  include Shops::Import::Woocommerce
  include Shops::Import::WixShop
  include Shops::Import::FaireShop
  include Shops::Import::SquarespaceShop
  include Shops::Import::Quickbooks

  attr_reader :shop
  attr_reader :external_import
  attr_accessor :price_conversion_note, :import_type

  # @attr_reader [String] currency the current currency
  attr_reader :currency

  def initialize(shop, external_import=nil, import_type=nil)
    @shop = shop
    @external_import = external_import
    @price_conversion_note = []
    @import_type = import_type
  end

  def self.call(shop, external_import=nil, import_type=nil)
    new(shop, external_import, import_type).call
  end

  # @return [Account] The account running the import
  def account
    @account ||= shop.account
  end

  # @return [Boolean] If the currency needs been converted when importing
  def price_converted(conversion_currency=nil)
    return send("#{shop.provider}_price_converted".downcase.to_sym, conversion_currency) if conversion_currency
    send("#{shop.provider}_price_converted".downcase.to_sym)
  end

  # @return [Boolean] If the currency needs been converted when importing
  def convert_amount(amount, date, conversion_note=nil, conversion_currency=nil)
    return send("#{shop.provider}_convert_amount".downcase.to_sym, amount, date, conversion_note, conversion_currency) if conversion_currency
    send("#{shop.provider}_convert_amount".downcase.to_sym, amount, date, conversion_note)
  end

  def token_active?
    send("#{shop.provider}_token_active?".downcase.to_sym)
  end

  # Generate a formatted log message to Rails.logger.info
  def log(message)
    log = []
    log << "#{self.class.name}"

    if !Rails.env.test? && shop.provider.to_sym == :shopify && shopify_last_header
      loop_count = 0
      current_shopify_limits = shopify_limits
      # Give ourself a 30% buffer to go back to processing data
      while current_shopify_limits.used*1.3 > current_shopify_limits.limit
        log << "Shopify Rate Limit:#{current_shopify_limits.used}/#{current_shopify_limits.limit}"
        sleep loop_count * 2 + 1
        loop_count += 1

        # Now that some time has passed, get the current limits again
        shopify_get("shop")["shop"]
        current_shopify_limits = shopify_limits
      end
    end
    log << "Provider:#{shop.provider.titleize}"
    log << "Shop:#{shop.id}"
    log << message
    Rails.logger.debug log.join(" ")
  end

  def start_date
    hourly? ? date_from : date_from.beginning_of_day
  end

  def end_date
    hourly? ? date_to : date_to.end_of_day
  end

  def date_from
    external_import.present? ? external_import.params[:date_from] : default_resync_time_range[:date_from]
  end

  def date_to
    external_import.present? ? external_import.params[:date_to] : default_resync_time_range[:date_to]
  end

  def hourly?
    import_type == :hourly
  end

  def default_resync_time_range
    @default_resync_time_range ||= if external_import.present?
      external_import.params
    else
      { date_from: [10.days.ago, account.start_date].max.beginning_of_day, date_to: Date.current.end_of_day }
    end
  end

  def handle_exception(e, context)
    return if ignore_error?(e.message)

    log "Exception: #{e.message}"
    external_import.update(
      failed_at: DateTime.now,
      error_messages: { message: e.message, backtrace: e.backtrace.map {|l| "  #{l}\n"}.join }
    ) if external_import

    Rollbar.error(e)
    CreateNotificationService.call(shop.account, shop.account.primary_user, "Your #{context} import for #{shop.name} (#{shop.provider}) failed.", "", "/shops/#{shop.id}/external_imports", "View imports")
    false
  end

  def ignore_error?(message)
    # Amazon returns HTTP Code 403 when the access token is expired
    ignore = 'code: 403'
    message.include?(ignore)
  end
end
