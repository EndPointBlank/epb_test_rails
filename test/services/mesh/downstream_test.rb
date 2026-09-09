# frozen_string_literal: true

require "test_helper"

# The one place in this application that speaks HTTP to a peer.
#
# Excon's own mock mode stands in for the peer, so this exercises the real
# request building, the real timeouts and the real response mapping without a
# socket, a mesh or a running peer anywhere.
class Mesh::DownstreamTest < ActiveSupport::TestCase
  BASE = "https://epb-test-ex.example.test"

  # Written out rather than read from Mesh::PATHS: these are the paths the
  # contract names, and a test that derived them from the implementation could
  # not notice the implementation changing them.
  RELAY_PATH = "/mesh/relay"
  REPORTS_PATH = "/mesh/reports"

  # The authorization seam. sc-263 is still deciding what credential each
  # call presents, so the real collaborator is EndPointBlank::Authorization
  # and swapping it is a constructor argument, not a monkey patch.
  class FakeAuthorization
    attr_reader :urls

    def initialize(value = "Bearer test-token")
      @value = value
      @urls = []
    end

    def header(url)
      @urls << url
      @value
    end
  end

  setup do
    @auth = FakeAuthorization.new
    @captured = []
    Excon.defaults[:mock] = true
  end

  teardown do
    Excon.stubs.clear
    Excon.defaults[:mock] = false
  end

  def stub_peer(status: 200, body: { "app" => "epb_test_ex", "terminated" => true }.to_json)
    Excon.stub({}, lambda do |request_params|
      @captured << request_params
      { status: status, body: body, headers: { "Content-Type" => "application/json" } }
    end)
  end

  def stub_peer_raising(error)
    Excon.stub({}, lambda do |request_params|
      @captured << request_params
      raise error
    end)
  end

  def downstream
    Mesh::Downstream.new(authorization: @auth)
  end

  # --- request building -----------------------------------------------------

  test "it posts to the path it was given under the configured base url" do
    # The path is the caller's, not this class's: /mesh/reports must reach the
    # peer's /mesh/reports, never its /mesh/relay.
    [ RELAY_PATH, REPORTS_PATH ].each do |path|
      @captured.clear
      stub_peer
      downstream.post(base_url: BASE, path: path, hops: 2, run: nil, payload: nil)

      assert_equal 1, @captured.length
      assert_equal :post, @captured.first[:method]
      assert_equal "epb-test-ex.example.test", @captured.first[:host]
      assert_equal path, @captured.first[:path]
    end
  end

  test "a trailing slash on the base url does not double the separator" do
    [ RELAY_PATH, REPORTS_PATH ].each do |path|
      @captured.clear
      stub_peer
      downstream.post(base_url: "#{BASE}/", path: path, hops: 1, run: nil, payload: nil)

      assert_equal path, @captured.first[:path]
    end
  end

  test "it forwards the decremented budget and the run identifier verbatim" do
    stub_peer
    downstream.post(base_url: BASE, path: RELAY_PATH, hops: 3, run: "RUN-abc", payload: nil)

    headers = @captured.first[:headers]
    assert_equal "3", headers["X-EPB-Test-Hops"]
    assert_equal "RUN-abc", headers["X-EPB-Test-Run"]
  end

  test "an absent run identifier sends no run header at all" do
    stub_peer
    downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    refute @captured.first[:headers].key?("X-EPB-Test-Run")
  end

  test "by default the seam is the application's own EndPointBlank client path" do
    # Not a raw HTTP client. The mesh exists to exercise cross-organization
    # authorization; a downstream call that bypassed the SDK would prove
    # nothing, so the default collaborator is asserted rather than assumed.
    assert_equal EndPointBlank::Authorization, Mesh::Downstream.new.authorization
  end

  test "the call is authorized through the EndPointBlank seam, for the url it is about to call" do
    stub_peer
    downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    assert_equal [ "#{BASE}/mesh/relay" ], @auth.urls
    assert_equal "Bearer test-token", @captured.first[:headers]["Authorization"]
  end

  test "the reports call is authorized for the reports url, not the relay one" do
    # The whole point of the negative control is that the authorization
    # decision is made about /mesh/reports. Authorizing the relay URL and then
    # calling reports -- or the reverse -- would ask the wrong question.
    stub_peer
    downstream.post(base_url: BASE, path: REPORTS_PATH, hops: 1, run: nil, payload: nil)

    assert_equal [ "#{BASE}/mesh/reports" ], @auth.urls
  end

  test "the body is JSON, and an absent payload is an empty object" do
    stub_peer
    downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)
    assert_equal({}, JSON.parse(@captured.first[:body]))
    assert_equal "application/json", @captured.first[:headers]["Content-Type"]

    @captured.clear
    downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: "opaque")
    assert_equal({ "payload" => "opaque" }, JSON.parse(@captured.first[:body]))
  end

  test "the contract's timeouts are the ones actually used" do
    assert_equal 3, Mesh::Downstream::CONNECT_TIMEOUT
    assert_equal 10, Mesh::Downstream::READ_TIMEOUT

    stub_peer
    downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    assert_equal 3, @captured.first[:connect_timeout]
    assert_equal 10, @captured.first[:read_timeout]
  end

  # --- response mapping -----------------------------------------------------

  test "a 200 with JSON is a usable response carrying the parsed body" do
    stub_peer(body: { "app" => "epb_test_ex", "hops_received" => 1 }.to_json)
    response = downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    assert response.ok?
    assert_equal 200, response.status
    assert_equal({ "app" => "epb_test_ex", "hops_received" => 1 }, response.body)
    assert_nil response.error
  end

  test "a non-200 preserves the status and is not ok" do
    stub_peer(status: 403, body: { "error" => "Authorization failed" }.to_json)
    response = downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    refute response.ok?
    assert_equal 403, response.status
    assert_includes response.error, "Authorization failed"
  end

  test "a transport failure has no status and reports the error" do
    stub_peer_raising(Excon::Error::Timeout.new("read timeout reached"))
    response = downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    refute response.ok?
    assert_nil response.status
    assert_includes response.error, "read timeout reached"
  end

  test "a connection failure has no status and reports the error" do
    stub_peer_raising(Excon::Error::Socket.new(StandardError.new("Connection refused")))
    response = downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    refute response.ok?
    assert_nil response.status
    assert_includes response.error, "Connection refused"
  end

  test "a 200 that is not JSON is a failure, not a silently empty success" do
    stub_peer(status: 200, body: "<html>a load balancer error page</html>")
    response = downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    refute response.ok?
    assert_equal 200, response.status
    assert_includes response.error, "not JSON"
  end

  test "the reported downstream error is truncated to 500 characters" do
    stub_peer(status: 500, body: "x" * 5_000)
    response = downstream.post(base_url: BASE, path: RELAY_PATH, hops: 1, run: nil, payload: nil)

    assert_equal 500, response.error.length
  end
end
