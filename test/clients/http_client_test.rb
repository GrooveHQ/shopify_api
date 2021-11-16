# typed: false
# frozen_string_literal: true

require_relative "../test_helper.rb"

class HttpClientTest < Test::Unit::TestCase
  def setup
    @shop = "test-shop.myshopify.com"
    @token = SecureRandom.alphanumeric(10)
    @base_path = "/base_path"
    @session = ShopifyAPI::Auth::Session.new(shop: @shop, access_token: @token)
    @client = ShopifyAPI::Clients::HttpClient.new(session: @session, base_path: @base_path)

    @request = ShopifyAPI::Clients::HttpRequest.new(
      http_method: :post,
      path: "some-path",
      body: { foo: "bar" },
      body_type: "application/json",
      query: { id: 1234 },
      extra_headers: { extra: "header" }
    )

    @expected_headers = {
      "Accept-Encoding": "gzip;q=1.0,deflate;q=0.6,identity;q=0.3",
      "User-Agent": "Shopify API Library v#{ShopifyAPI::VERSION} | Ruby #{RUBY_VERSION}",
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-Shopify-Access-Token": @token,
    }.merge(@request.extra_headers)

    @success_body = { "success" => true }
    @response_headers = { "content-type" => "application/json", "x-request-id" => "123" }
  end

  def test_get
    simple_http_test(:get)
  end

  def test_delete
    simple_http_test(:delete)
  end

  def test_put
    simple_http_test(:put)
  end

  def test_post
    simple_http_test(:post)
  end

  def test_request_with_empty_base_path
    @base_path = ""
    @client = ShopifyAPI::Clients::HttpClient.new(session: @session, base_path: @base_path)
    simple_http_test(:get)
  end

  def test_request_with_empty_response_body
    @success_body = {}

    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: "", headers: @response_headers)

    verify_http_request
  end

  def test_request_with_no_access_token
    @session = ShopifyAPI::Auth::Session.new(shop: @shop)
    @client = ShopifyAPI::Clients::HttpClient.new(session: @session, base_path: @base_path)

    @expected_headers.delete(:"X-Shopify-Access-Token")

    apply_simple_http_stub
    verify_http_request
  end

  def test_request_with_no_optional_parameters
    @request = ShopifyAPI::Clients::HttpRequest.new(http_method: :get, path: @request.path)

    @expected_headers.delete(:extra)
    @expected_headers.delete(:"Content-Type")

    stub_request(:get, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(headers: @expected_headers)
      .to_return(body: @success_body.to_json, headers: @response_headers)

    verify_http_request
  end

  def test_request_with_invalid_request
    @request.http_method = :bad
    assert_raises(ShopifyAPI::Errors::InvalidHttpRequestError) { @client.request(@request) }
  end

  def test_non_retriable_error_code
    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: { errors: "Something very not good" }.to_json, headers: @response_headers, status: 400)

    assert_raises(ShopifyAPI::Errors::HttpResponseError) { @client.request(@request) }
  end

  def test_retriable_error_code_no_retries
    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: { errors: "Something very not good" }.to_json, headers: @response_headers, status: 500)

    assert_raises(ShopifyAPI::Errors::HttpResponseError) { @client.request(@request) }
  end

  def test_retry_throttle_error
    @request.tries = 2

    @client.expects(:sleep).with(2).times(1)

    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: { errors: "Something very not good" }.to_json,
        headers: @response_headers.merge("Retry-After" => "2.0"), status: 429).times(1)
      .then.to_return(body: @success_body.to_json, headers: @response_headers)

    verify_http_request
  end

  def test_retry_internal_error
    @request.tries = 2

    @client.expects(:sleep).with(1).times(1)

    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: { errors: "Something very not good" }.to_json, headers: @response_headers, status: 500)
      .times(1)
      .then.to_return(body: @success_body.to_json, headers: @response_headers)

    verify_http_request
  end

  def test_retries_exceeded
    @request.tries = 3

    @client.expects(:sleep).with(1).times(2)

    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: { errors: "Something very not good" }.to_json, headers: @response_headers, status: 500)

    assert_raises(ShopifyAPI::Errors::MaxHttpRetriesExceededError) { @client.request(@request) }
  end

  def test_throttle_error_no_retry_after_header
    @request.tries = 2

    @client.expects(:sleep).with(1).times(1)

    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: { errors: "Something very not good" }.to_json, headers: @response_headers, status: 429)
      .times(1)
      .then.to_return(body: @success_body.to_json, headers: @response_headers)

    verify_http_request
  end

  def test_warns_on_deprecation_header
    deprecate_reason = "https://help.shopify.com/tutorials#foobar-endpoint-is-removed"
    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: @success_body.to_json,
        headers: @response_headers.merge("X-Shopify-API-Deprecated-Reason" => deprecate_reason))

    @client.expects(:warn).with(regexp_matches(/#{@request.path}.*#{deprecate_reason}/)).times(1)
    @client.request(@request)
  end

  private

  def simple_http_test(http_method)
    @request.http_method = http_method
    apply_simple_http_stub
    verify_http_request
  end

  def apply_simple_http_stub
    stub_request(@request.http_method, "https://#{@shop}#{@base_path}/#{@request.path}")
      .with(body: @request.body.to_json, query: @request.query, headers: @expected_headers)
      .to_return(body: @success_body.to_json, headers: @response_headers)
  end

  def verify_http_request
    response = @client.request(@request)

    assert(response.ok?)
    assert_equal(@success_body, response.body)
    assert_equal(@response_headers.map { |k, v| [k, [v]] }.to_h, response.headers)
  end
end
