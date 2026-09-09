# frozen_string_literal: true

require "test_helper"

# The two mesh endpoints, end to end through the real router, the real
# EndPointBlank authorization filter and the real controller.
#
# Only two things are stubbed, and both are the network: the EPB authorize
# call (intake) and the downstream peer. Nothing here needs staging, AWS,
# app_portal, intake or a mesh.
class MeshControllerTest < ActionDispatch::IntegrationTest
  DOWNSTREAM = "https://epb-test-ex.example.test"

  # Records every downstream call and answers however the test told it to.
  class Peer
    attr_reader :calls

    def initialize(status: 200, body: nil, error: nil)
      @status = status
      @body = body || { "app" => "epb_test_ex", "hops_received" => 0, "terminated" => true }
      @error = error
      @calls = []
    end

    def post(base_url:, hops:, run:, payload:)
      @calls << { base_url: base_url, hops: hops, run: run, payload: payload }
      Mesh::Downstream::Response.new(status: @status, body: @error ? nil : @body, error: @error)
    end
  end

  class ForbiddenPeer
    def post(**)
      raise "the controller called downstream when it must not have"
    end
  end

  def granted(body = { "data" => [ { "source_application_environment_id" => "app-env-test" } ] })
    EndPointBlank::Commands::CachedResponse.new(201, body.to_json)
  end

  def refused(status = 403, body = { "error" => "endpoint not granted to this application" })
    EndPointBlank::Commands::CachedResponse.new(status, body.to_json)
  end

  # Run the block with the EPB authorize call answering `result`, and with
  # Mesh::Downstream.new handing back `peer`.
  def with_epb(authorize: granted, peer: ForbiddenPeer.new)
    stubbing(EndPointBlank::Commands::EndpointAuthorize, :authorize, ->(*, **) { authorize }) do
      stubbing(Mesh::Downstream, :new, ->(*, **) { peer }) do
        yield
      end
    end
  end

  def body
    JSON.parse(response.body)
  end

  # --- the endpoints are behind the same authorization as the demo routes ---

  test "a refused relay is refused, not relayed" do
    peer = ForbiddenPeer.new
    with_epb(authorize: refused, peer: peer) do
      post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "4" }
    end

    assert_response :forbidden
    assert_includes body["error"], "endpoint not granted"
  end

  test "the reports endpoint -- the negative control -- is refused the same way" do
    with_epb(authorize: refused) do
      post "/mesh/reports", headers: { "X-EPB-Test-Hops" => "4" }
    end

    assert_response :forbidden
  end

  test "an unreachable authorization service is a 503, not an open door" do
    with_epb(authorize: nil) do
      post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "4" }
    end

    assert_response :service_unavailable
  end

  # --- terminating ----------------------------------------------------------

  test "an exhausted budget answers, calls nobody and says it terminated" do
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb do
        post "/mesh/relay",
          params: { payload: "hello" }.to_json,
          headers: { "Content-Type" => "application/json", "X-EPB-Test-Hops" => "0", "X-EPB-Test-Run" => "run-7" }
      end
    end

    assert_response :success
    assert_equal "epb_test_rails", body["app"]
    assert_equal 0, body["hops_received"]
    assert_nil body["hops_forwarded"]
    assert_equal true, body["terminated"]
    assert_equal "run-7", body["run"]
    assert_equal "hello", body["payload"]
    assert_nil body["downstream"]
  end

  test "a missing hops header terminates rather than running away" do
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb { post "/mesh/relay" }
    end

    assert_response :success
    assert_equal 0, body["hops_received"]
    assert_equal true, body["terminated"]
  end

  test "every zero case in the parse table terminates over HTTP too" do
    [ "", " ", "abc", "1.5", "0x4", "+4", "four", "-1", "-100", "0" ].each do |raw|
      with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
        with_epb { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => raw } }
      end

      assert_response :success, "#{raw.inspect} should answer 200"
      assert_equal 0, body["hops_received"], "#{raw.inspect} should be 0 hops"
      assert_equal true, body["terminated"], "#{raw.inspect} should terminate"
    end
  end

  test "an empty body and no body at all are both accepted" do
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb do
        post "/mesh/relay", params: "{}", headers: { "Content-Type" => "application/json", "X-EPB-Test-Hops" => "0" }
      end
      assert_response :success
      assert_nil body["payload"]

      with_epb do
        post "/mesh/relay", headers: { "Content-Type" => "application/json", "X-EPB-Test-Hops" => "0" }
      end
      assert_response :success
      assert_nil body["payload"]
    end
  end

  # --- relaying -------------------------------------------------------------

  test "a live budget makes exactly one downstream call with the budget decremented" do
    peer = Peer.new
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) do
        post "/mesh/relay",
          params: { payload: "p" }.to_json,
          headers: { "Content-Type" => "application/json", "X-EPB-Test-Hops" => "3", "X-EPB-Test-Run" => "run-7" }
      end
    end

    assert_response :success
    assert_equal 1, peer.calls.length
    assert_equal DOWNSTREAM, peer.calls.first[:base_url]
    assert_equal 2, peer.calls.first[:hops]
    assert_equal "run-7", peer.calls.first[:run]
    assert_equal "p", peer.calls.first[:payload]

    assert_equal 3, body["hops_received"]
    assert_equal 2, body["hops_forwarded"]
    assert_equal false, body["terminated"]
    assert_equal "epb_test_ex", body["downstream"]["app"]
  end

  test "the reports endpoint behaves identically to relay when it is reached" do
    peer = Peer.new
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) do
        post "/mesh/reports", headers: { "X-EPB-Test-Hops" => "2" }
      end
    end

    assert_response :success
    assert_equal 1, peer.calls.length
    assert_equal 1, peer.calls.first[:hops]
    assert_equal 2, body["hops_received"]
  end

  test "a clamped budget is reported as the clamp, and forwards one below it" do
    peer = Peer.new
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "1000000" } }
    end

    assert_response :success
    assert_equal 64, body["hops_received"]
    assert_equal 63, body["hops_forwarded"]
    assert_equal 63, peer.calls.first[:hops]
  end

  # --- misconfiguration is loud --------------------------------------------

  test "a live budget with no downstream configured is a 500 with a named error" do
    with_env("EPB_MESH_DOWNSTREAM_URL" => nil) do
      with_epb { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "4" } }
    end

    assert_response :internal_server_error
    assert_equal "downstream_not_configured", body["error"]
    assert_equal "epb_test_rails", body["app"]
    assert_equal 4, body["hops_received"]
    assert_includes body["message"], "EPB_MESH_DOWNSTREAM_URL"
    # A silent stop would look exactly like a working mesh that terminated.
    refute_equal true, body["terminated"]
  end

  test "an empty downstream url is treated as no downstream url" do
    with_env("EPB_MESH_DOWNSTREAM_URL" => "") do
      with_epb { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "1" } }
    end

    assert_response :internal_server_error
    assert_equal "downstream_not_configured", body["error"]
  end

  # --- downstream failure ---------------------------------------------------

  test "a downstream refusal surfaces as a 502 that preserves the status" do
    peer = Peer.new(status: 403, error: "Authorization failed: endpoint not granted")
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "3" } }
    end

    assert_response :bad_gateway
    assert_equal "downstream_failed", body["error"]
    assert_equal 403, body["downstream_status"]
    assert_equal 3, body["hops_received"]
    assert_includes body["downstream_error"], "endpoint not granted"
  end

  test "a downstream transport failure is a 502 with no status to preserve" do
    peer = Peer.new(status: nil, error: "Excon::Error::Timeout: read timeout reached")
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "1" } }
    end

    assert_response :bad_gateway
    assert_equal "downstream_failed", body["error"]
    assert_nil body["downstream_status"]
  end

  # --- routing --------------------------------------------------------------

  test "the mesh endpoints are POST only" do
    assert_routing({ method: :post, path: "/mesh/relay" }, { controller: "mesh", action: "relay" })
    assert_routing({ method: :post, path: "/mesh/reports" }, { controller: "mesh", action: "reports" })
    get "/mesh/relay"
    assert_response :not_found
  end
end
