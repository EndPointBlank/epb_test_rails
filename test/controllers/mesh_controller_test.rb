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

  # Written out rather than read from Mesh::PATHS: these are the paths the
  # contract names, and a test that derived them from the implementation could
  # not notice the implementation changing them.
  RELAY_PATH = "/mesh/relay"
  REPORTS_PATH = "/mesh/reports"

  # Records every downstream call and answers however the test told it to.
  class Peer
    attr_reader :calls

    def initialize(status: 200, body: nil, error: nil, origin: nil)
      @status = status
      @body = body || { "app" => "epb_test_ex", "hops_received" => 0, "terminated" => true }
      @error = error
      @origin = origin
      @calls = []
    end

    def post(base_url:, path:, hops:, run:, payload:)
      @calls << { base_url: base_url, path: path, hops: hops, run: run, payload: payload }
      Mesh::Downstream::Response.new(
        status: @status, body: @error ? nil : @body, error: @error, origin: @origin
      )
    end
  end

  # A peer provisioned the way sc-263 actually provisions the ring: `core` is
  # granted, `reports` is not. It answers by path, so a relay call succeeds and
  # a reports call is refused by the peer's own authorization layer.
  class PathSensitivePeer
    attr_reader :calls

    def initialize(granted: [ RELAY_PATH ])
      @granted = granted
      @calls = []
    end

    def post(base_url:, path:, hops:, run:, payload:)
      @calls << { base_url: base_url, path: path, hops: hops, run: run, payload: payload }

      if @granted.include?(path)
        Mesh::Downstream::Response.new(
          status: 200,
          body: { "app" => "epb_test_ex", "hops_received" => hops, "terminated" => true },
          error: nil
        )
      else
        Mesh::Downstream::Response.new(
          status: 403,
          body: nil,
          error: "Authorization failed: endpoint not granted to this application"
        )
      end
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
    assert_equal RELAY_PATH, peer.calls.first[:path]
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

  test "a reports request is forwarded onto the downstream reports endpoint" do
    # The path is preserved across hops. Forwarding reports onto /mesh/relay
    # would launder the negative control into ordinary relay traffic the moment
    # it was wrongly granted at hop one.
    peer = Peer.new
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/reports", headers: { "X-EPB-Test-Hops" => "2" } }
    end

    assert_response :success
    assert_equal REPORTS_PATH, peer.calls.first[:path]
    assert_equal DOWNSTREAM, peer.calls.first[:base_url]
  end

  test "a downstream that grants relay but refuses reports fails loudly instead of relaying" do
    # The exact provisioning failure the preserved-path rule exists for: this
    # application is wrongly granted `reports` at hop one, so the request gets
    # in. Because the path survives, the next hop -- provisioned correctly --
    # refuses it, and the entry point answers 502 rather than a clean 200 with
    # a successful relay nested inside it.
    peer = PathSensitivePeer.new(granted: [ RELAY_PATH ])
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/reports", headers: { "X-EPB-Test-Hops" => "3" } }
    end

    assert_response :bad_gateway
    assert_equal REPORTS_PATH, peer.calls.first[:path]
    assert_equal "downstream_failed", body["error"]
    assert_equal 403, body["downstream_status"]
    assert_equal 3, body["hops_received"]
    assert_includes body["downstream_error"], "not granted"
    refute body.key?("downstream"), "a laundered relay must not be nested under a refused reports call"

    # And the same peer relays a /mesh/relay call perfectly well, so the 502
    # above is the path being preserved and not a broken peer.
    relay_peer = PathSensitivePeer.new(granted: [ RELAY_PATH ])
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: relay_peer) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "3" } }
    end

    assert_response :success
    assert_equal RELAY_PATH, relay_peer.calls.first[:path]
    assert_equal "epb_test_ex", body["downstream"]["app"]
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

  # --- origin, over HTTP (sc-290) -------------------------------------------

  test "a 502 names who refused, in origin, as well as what this hop called" do
    peer = Peer.new(status: 403, error: "Authorization failed: endpoint not granted")
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "2" } }
    end

    assert_response :bad_gateway
    # Per-hop, unchanged by sc-290.
    assert_equal 403, body["downstream_status"]
    # End-to-end, and serialized as a real JSON object rather than a string.
    assert_equal "epb_test_rails", body["origin"]["app"]
    assert_equal 403, body["origin"]["status"]
    assert_equal 2, body["origin"]["hops_received"]
    assert_includes body["origin"]["error"], "endpoint not granted"
  end

  test "an origin from further down survives the whole controller unchanged" do
    deep = { "app" => "epb_test_js", "status" => 403, "hops_received" => 1, "error" => "access_denied" }
    peer = Peer.new(status: 502, error: "the hop below answered 502", origin: deep)
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "4" } }
    end

    assert_response :bad_gateway
    assert_equal deep, body["origin"], "the deepest failure going up wins"
    assert_equal 502, body["downstream_status"], "and the per-hop status is still this hop's"
    assert_equal 4, body["hops_received"]
  end

  test "a transport failure attributes itself with a null origin status" do
    peer = Peer.new(status: nil, error: "Excon::Error::Timeout: read timeout reached")
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: peer) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "1" } }
    end

    assert_response :bad_gateway
    assert_equal "epb_test_rails", body["origin"]["app"]
    assert_nil body["origin"]["status"]
    assert_equal 1, body["origin"]["hops_received"]
  end

  test "a successful relay answers with no origin key at all" do
    with_env("EPB_MESH_DOWNSTREAM_URL" => DOWNSTREAM) do
      with_epb(peer: Peer.new) { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "2" } }
    end

    assert_response :success
    refute body.key?("origin"), "there is nothing to attribute on the happy path"
  end

  test "the unconfigured-downstream 500 is unchanged, and carries no origin" do
    # It is not a downstream failure: no request left, nothing refused, and
    # nothing for sc-265 to count as a refusal. The contract enumerates this
    # body exactly -- app, hops_received, error, message -- so origin stays off
    # it, the same way terminated does.
    with_env("EPB_MESH_DOWNSTREAM_URL" => nil) do
      with_epb { post "/mesh/relay", headers: { "X-EPB-Test-Hops" => "2" } }
    end

    assert_response :internal_server_error
    assert_equal %w[app hops_received error message].sort, body.keys.sort
    refute body.key?("origin")
    refute body.key?("terminated")
  end

  # --- routing --------------------------------------------------------------

  test "the mesh endpoints are POST only" do
    assert_routing({ method: :post, path: "/mesh/relay" }, { controller: "mesh", action: "relay" })
    assert_routing({ method: :post, path: "/mesh/reports" }, { controller: "mesh", action: "reports" })
    get "/mesh/relay"
    assert_response :not_found
  end

  test "the registered routes and the forwarded paths are the same definition" do
    # The forwarded path must EQUAL the inbound path, so the route this
    # application answers and the path it calls downstream come from
    # Mesh::PATHS and nowhere else. Pinned against the contract's literals
    # here, once, so the rest of the suite can use the constant freely.
    assert_equal({ "relay" => RELAY_PATH, "reports" => REPORTS_PATH }, Mesh::PATHS)

    Mesh::PATHS.each do |action, path|
      assert_routing({ method: :post, path: path }, { controller: "mesh", action: action })
      assert_equal path, Mesh.path_for(action)
    end
  end

  test "the mesh endpoints are mounted at the root, because the mount is part of the wire contract" do
    # A prefix -- an engine at /api/mesh, say -- would make every next hop 404,
    # and with the path preserved it would do so for both endpoints rather than
    # only for reports. Cheap to assert, and it fails as a routing problem
    # rather than surfacing later as an inexplicable authorization one.
    Mesh::PATHS.each_value do |path|
      assert_equal 2, path.count("/"), "#{path} must be rooted, not mounted under a prefix"
      assert path.start_with?("/mesh/"), "#{path} must be served at the root"
    end
  end
end
