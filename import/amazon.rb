module Shops::Import::Amazon
  include Shops::Import::Amazon::Expenses
  include Shops::Import::Amazon::Listings
  include Shops::Import::Amazon::Orders

  class NoDocumentId < StandardError
    def initialize(message, report=nil)
      @report = report
      super(message)
    end
  end

  def amazon_api_rate_limiter
    hash = "shop:#{shop.id}:request:#{DateTime.now.minute}".downcase
    request_count = $redis.get(hash) || 0
    if request_count.to_i > 20
      # We've hit our per minute limit so sleep for the remaining minute
      remaining_time = 61 - DateTime.now.second
      sleep remaining_time
    else
      # Increment the counter and move on
      $redis.multi do |multi|
        multi.incr(hash)
        multi.expire(hash, 61)
      end
    end
  end

  def amazon_token_active?
    amazon_sellers_api_model.get_marketplace_participations.payload.present?
  rescue StandardError
    refreshed ||= false
    unless refreshed
      amazon_client.refresh
      amazon_config.credentials_provider = Aws::STS::Client.new(
        region: AmzSpApi::SpConfiguration::AWS_REGION_MAP['na'],
        access_key_id: ENV['xxx'],
        secret_access_key: ENV['xxx']
      ).assume_role(role_arn: 'xxx', role_session_name: SecureRandom.uuid)
      refreshed = true
      retry
    end
    false
  end

  def amazon_min_created
    start_date.utc.iso8601
  end

  def amazon_max_created(date = date_to)
    if date >= DateTime.current
      1.hour.ago 
    else
      date_to.change(hour: DateTime.current.hour - 1)
    end.utc.iso8601
  end

  # Converts the amount into the accounts currency on the date provided
  #
  # @return [BigDecimal] the converted or original amount
  def amazon_convert_amount(amount, date, conversion_note=nil)
    if amazon_price_converted?
      exchaned_amount = CurrencyExchangeRate.exchange(amount, date, amazon_default_currency_code, account.currency_code)
      price_conversion_note << "#{conversion_note}: #{exchaned_amount[:conversion_note]}" if conversion_note
      exchaned_amount[:converted_amount]
    else
      BigDecimal(amount.to_s.blank? ? 0 : amount.to_s)
    end
  end

  def amazon_price_converted?
    amazon_default_currency_code != account.currency_code
  end

  def amazon_default_currency_code
    return @amazon_default_currency_code if @amazon_default_currency_code.present?
    @amazon_default_currency_code = amazon_default_marketplace.default_currency_code

    # marketplace_participations.first.marketplace.default_currency_code
  end

  # @return [Array] A CSV array of Amazon products
  def amazon_products
    # client.call_api(:get, "/listings/2021-08-01/items/#{shop.external_shop_id}")
    report_id = nil

    retry_with_limit do
      create_opts = {
        body: {
          reportType: "GET_MERCHANT_LISTINGS_ALL_DATA",
          marketplaceIds: amazon_marketplace_ids
        }
      }
      report_id = amazon_report_api_model.create_report("", create_opts).payload[:reportId]
    end

    retry_with_limit do
      url = get_report_document_url(report_id)
      return [] unless url
      csv = CSV.new(open(url), headers: :first_row, liberal_parsing: true, col_sep: "\t").read
      filter_active_products csv
    end
  end

  def amazon_fba_fulfilled_shipments(data_start_time = amazon_min_created, data_end_time = amazon_max_created)
    report_id = nil

    retry_with_limit do
      create_opts = {
        body: {
          reportType: "GET_AMAZON_FULFILLED_SHIPMENTS_DATA_GENERAL",
          marketplaceIds: amazon_marketplace_ids,
          dataStartTime: data_start_time,
          dataEndTime: data_end_time
        }
      }
      report_id = amazon_report_api_model.create_report("", create_opts).payload[:reportId]
    end

    retry_with_limit do
      url = get_report_document_url(report_id)
      return [] unless url
      CSV.new(open(url), headers: :first_row, liberal_parsing: true, col_sep: "\t").read
    end
  end

  def amazon_list_financial_events(opts)
    retry_with_limit do
      payload = amazon_finances_api_model.list_financial_events(opts).payload
      [amazon_hash_to_object(payload[:FinancialEvents]), payload[:NextToken]]
    end
  end

  def amazon_orders(opts)
    retry_with_limit do
      payload = amazon_order_api_model.get_orders(amazon_marketplace_ids, opts).payload
      [payload[:Orders].map { |order| amazon_hash_to_object(order) }, payload[:NextToken]]
    end
  end

  def amazon_order_info(order_id)
    order_info = amazon_hash_to_object(amazon_order_api_model.get_order(order_id).payload)
    if order_info.buyer_info.present?
      order_info.buyer_info.buyer_name = amazon_order_api_model
        .get_order_address(order_id).payload.dig(:ShippingAddress,:Name)
    end
    order_info
  end

  def amazon_order_items(order_id)
    amazon_hash_to_object amazon_order_api_model.get_order_items(order_id).payload
  end

  # Pings the Amazon API to get a Services Status
  # @return [Boolean] Indicating Amazon is available
  # def amazon_available?
  #   begin
  #     response = amazon_sellers_client.get_service_status
  #     response.parse["Status"] == "GREEN"
  #   rescue
  #     false
  #   end
  # end


  # def self.marketplace_id(refresh_token)
  #   config = AmzSpApi::SpConfiguration.default
  #   config.refresh_token = refresh_token
  #   client = AmzSpApi::SpApiClient.new(config)
  #   AmzSpApi::SellersApiModel::SellersApi.new(client).get_marketplace_participations.payload.first[:marketplace][:id]
  # end

  private

  def retry_with_limit(max_attempts = 3, sleep_duration = 60)
    attempt = 1
    begin
      yield
    rescue AmzSpApi::ApiError => err
      raise err if attempt >= max_attempts
      attempt += 1
      sleep sleep_duration
      retry
    end
  end

  def amazon_report_api_model
    @report_api_model ||= AmzSpApi::ReportsApiModel::ReportsApi.new(amazon_client)
  end

  def amazon_finances_api_model
    @finances_api_model ||= AmzSpApi::FinancesApiModel::DefaultApi.new(amazon_client)
  end

  def amazon_authorization_api_model
    @authorization_api_model ||= AmzSpApi::AuthorizationApiModel::AuthorizationApi.new(amazon_client)
  end

  def amazon_order_api_model
    @order_api_model ||= AmzSpApi::OrdersApiModel::OrdersV0Api.new(amazon_client)
  end

  def amazon_sellers_api_model
    @sellers_api_model ||= AmzSpApi::SellersApiModel::SellersApi.new(amazon_client)
  end

  def amazon_marketplace_ids
    return [amazon_default_marketplace.id]
    #TODO consider multiple mp's
    # return @amazon_marketplace_ids if @amazon_marketplace_ids.present?
    # @amazon_marketplace_ids = marketplace_participations.map do |mp|
    #   mp.marketplace.id
    # end
  end

  def amazon_default_marketplace
    return @amazon_default_marketplace if @amazon_default_marketplace.present?
    @amazon_default_marketplace = amazon_marketplace_participations.find { |d| d.marketplace.id == 'ATVPDKIKX0DER' }
     .marketplace
  end

  def amazon_marketplace_participations
    return @amazon_marketplace_participations if @amazon_marketplace_participations.present?
    @amazon_marketplace_participations = amazon_sellers_api_model
      .get_marketplace_participations.payload.map { |mp| amazon_hash_to_object(mp) }
  end

  def amazon_config
    config = AmzSpApi::SpConfiguration.default.dup
    config.refresh_token = shop.authentication.refresh_token
    config.credentials_provider = Aws::STS::Client.new(
      region: AmzSpApi::SpConfiguration::AWS_REGION_MAP['na'],
      access_key_id: ENV['xxx'],
      secret_access_key: ENV['xxx']
    ).assume_role(role_arn: 'xxx', role_session_name: SecureRandom.uuid)
    config
  end

  def amazon_client
    @amazon_client ||= AmzSpApi::SpApiClient.new(amazon_config)
  end

  def get_report_document_url(report_id)
    report_payload = amazon_report_api_model.get_report(report_id).payload
    processing_status = report_payload[:processingStatus].downcase
    if processing_status == "done"
      amazon_report_api_model.get_report_document(report_payload[:reportDocumentId]).payload[:url]
    else
      raise AmzSpApi::ApiError, "Report processing status: #{processing_status}"
    end
  end

  def amazon_hash_to_object(hash)
    JSON.parse(
      hash.deep_transform_keys { |key| key.to_s.underscore }.to_json,
      object_class: OpenStruct
    )
  end

  # Function to filter out duplicate inactive rows and keep unique rows with active status
  def filter_active_products(csv_data)
    data_array = csv_data.map(&:to_h)
    unique_rows = {}

    data_array.each do |row|
      asin = row['asin1']
      status = row['status']

      # If the asin is not in the hash, or if it is but the current row is Active, store/overwrite it
      if !unique_rows.key?(asin) || (unique_rows[asin]['status'] == 'Inactive' && status == 'Active')
        unique_rows[asin] = row
      end
    end

    unique_rows.values
  end
end
