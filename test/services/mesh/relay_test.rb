# frozen_string_literal: true

require "test_helper"

# Termination, proved against a stub rather than observed once.
#
# The ring in sc-263 is epb_test_ex -> _java -> _js -> _py -> _rails -> _ex.
# Nothing in that shape stops on its own; only the budget does. So the
# headline test here builds a ring out of this very class -- the fake
# downstream re-enters Mesh::Relay with the hop count it was handed, exactly
# as a peer application would -- and counts the calls. No HTTP, no staging,
# no mesh.
class Mesh::RelayTest < ActiveSupport::TestCase
  DOWNSTREAM = "https://epb-test-ex.example.test"

  # A peer that is this same application. Every call it receives is recorded,
  # then handed to a fresh Relay wired back to this same object, so N nodes of
  # the ring are simulated by one counter.
  class RingPeer
    attr_reader :calls

    def initialize(downstream_url: DOWNSTREAM)
      @calls = []
      @downstream_url = downstream_url
    end

    def post(base_url:, hops:, run:, payload:)
      @calls << { base_url: base_url, hops: hops, run: run, payload: payload }

      status, body = Mesh::Relay.new(
        app_name: "epb_test_peer",
        downstream_url: @downstream_url,
        downstream: self
      ).call(hops_header: hops.to_s, run: run, payload: payload)

      # The real downstream hands back parsed JSON, i.e. string keys. Round
      # trip so this stub cannot make the caller look better than it is.
      Mesh::Downstream::Response.new(status: status, body: JSON.parse(body.to_json), error: nil)
    end
  end

  # A peer that always fails, the way a refusal or an unreachable host does.
  class FailingPeer
    attr_reader :calls

    def initialize(status:, error:)
      @status = status
      @error = error
      @calls = []
    end

    def post(base_url:, hops:, run:, payload:)
      @calls << { base_url: base_url, hops: hops, run: run, payload: payload }
      Mesh::Downstream::Response.new(status: @status, body: nil, error: @error)
    end
  end

  # A peer that must never be called.
  class ForbiddenPeer
    def post(**)
      raise "the relay called downstream when it must not have"
    end
  end

  def relay(downstream:, downstream_url: DOWNSTREAM, app_name: "epb_test_rails")
    Mesh::Relay.new(app_name: app_name, downstream_url: downstream_url, downstream: downstream)
  end

  # --- termination ----------------------------------------------------------

  test "a budget of N produces exactly N downstream calls" do
    (0..6).each do |budget|
      peer = RingPeer.new
      relay(downstream: peer).call(hops_header: budget.to_s, run: nil, payload: nil)

      assert_equal budget, peer.calls.length,
        "budget #{budget} should make exactly #{budget} downstream calls"
    end
  end

  test "a budget of N touches N+1 applications, one deeper per hop" do
    status, body = relay(downstream: RingPeer.new).call(hops_header: "4", run: nil, payload: nil)

    assert_equal 200, status

    depth = 0
    node = body.deep_stringify_keys
    while node["downstream"]
      depth += 1
      node = node["downstream"]
    end

    assert_equal 4, depth, "nesting depth should equal the budget"
    assert_equal true, node["terminated"], "the innermost application must be the terminating one"
    assert_nil node["downstream"]
    assert_nil node["hops_forwarded"]
  end

  test "the forwarded budget decrements by exactly one per hop, down to zero" do
    peer = RingPeer.new
    relay(downstream: peer).call(hops_header: "5", run: nil, payload: nil)

    assert_equal [ 4, 3, 2, 1, 0 ], peer.calls.map { |c| c[:hops] }
  end

  test "a clamped budget still terminates, at the clamp" do
    peer = RingPeer.new
    relay(downstream: peer).call(hops_header: "1000000", run: nil, payload: nil)

    assert_equal Mesh::HopBudget::MAX, peer.calls.length
  end

  # --- the terminating answer ----------------------------------------------

  test "an exhausted budget answers and calls nobody" do
    status, body = relay(downstream: ForbiddenPeer.new).call(
      hops_header: "0", run: "run-1", payload: "hello"
    )

    assert_equal 200, status
    assert_equal({
      app: "epb_test_rails",
      hops_received: 0,
      hops_forwarded: nil,
      terminated: true,
      run: "run-1",
      payload: "hello",
      downstream: nil
    }, body)
  end

  test "every zero case in the parse table terminates rather than calling downstream" do
    [ nil, "", "   ", "abc", "1.5", "0x4", "+4", "four", "-1", "-100", "0" ].each do |raw|
      status, body = relay(downstream: ForbiddenPeer.new).call(hops_header: raw, run: nil, payload: nil)

      assert_equal 200, status, "#{raw.inspect} should answer 200"
      assert_equal true, body[:terminated], "#{raw.inspect} should terminate"
      assert_equal 0, body[:hops_received], "#{raw.inspect} should be received as 0 hops"
      assert_nil body[:hops_forwarded]
      assert_nil body[:downstream]
    end
  end

  test "an exhausted budget terminates even with no downstream configured" do
    # Budget exhaustion and a missing target are different events. This one is
    # a normal answer; the other, below, is a 500.
    status, body = relay(downstream: ForbiddenPeer.new, downstream_url: nil).call(
      hops_header: "0", run: nil, payload: nil
    )

    assert_equal 200, status
    assert_equal true, body[:terminated]
  end

  # --- the successful relay -------------------------------------------------

  test "a live budget nests the downstream response verbatim" do
    peer = RingPeer.new
    status, body = relay(downstream: peer).call(hops_header: "2", run: "run-9", payload: "p")

    assert_equal 200, status
    assert_equal "epb_test_rails", body[:app]
    assert_equal 2, body[:hops_received]
    assert_equal 1, body[:hops_forwarded]
    assert_equal false, body[:terminated]
    assert_equal "run-9", body[:run]
    assert_equal "p", body[:payload]
    assert_equal "epb_test_peer", body[:downstream]["app"]
    assert_equal 1, body[:downstream]["hops_received"]
  end

  test "the run identifier is forwarded verbatim and never generated" do
    peer = RingPeer.new
    _status, body = relay(downstream: peer).call(hops_header: "3", run: "  Run/ID:7  ", payload: nil)

    assert_equal [ "  Run/ID:7  " ] * 3, peer.calls.map { |c| c[:run] }
    assert_equal "  Run/ID:7  ", body[:run]
  end

  test "an absent run identifier stays absent and is not invented" do
    peer = RingPeer.new
    _status, body = relay(downstream: peer).call(hops_header: "2", run: nil, payload: nil)

    assert_equal [ nil, nil ], peer.calls.map { |c| c[:run] }
    assert_nil body[:run]
  end

  test "the payload is echoed and forwarded" do
    peer = RingPeer.new
    _status, body = relay(downstream: peer).call(hops_header: "1", run: nil, payload: "opaque")

    assert_equal [ "opaque" ], peer.calls.map { |c| c[:payload] }
    assert_equal "opaque", body[:payload]
    assert_equal "opaque", body[:downstream]["payload"]
  end

  # --- misconfiguration is loud --------------------------------------------

  test "a live budget with no downstream configured raises rather than stopping quietly" do
    error = assert_raises(Mesh::DownstreamNotConfiguredError) do
      relay(downstream: ForbiddenPeer.new, downstream_url: nil).call(
        hops_header: "3", run: nil, payload: nil
      )
    end

    assert_equal 3, error.hops_received
    assert_includes error.message, "EPB_MESH_DOWNSTREAM_URL"
  end

  test "a blank downstream url counts as unconfigured" do
    [ "", "   " ].each do |blank|
      assert_raises(Mesh::DownstreamNotConfiguredError) do
        relay(downstream: ForbiddenPeer.new, downstream_url: blank).call(
          hops_header: "1", run: nil, payload: nil
        )
      end
    end
  end

  # --- downstream failure ---------------------------------------------------

  test "a downstream refusal becomes a 502 that preserves the status" do
    peer = FailingPeer.new(status: 403, error: "Authorization failed: endpoint not granted")
    status, body = relay(downstream: peer).call(hops_header: "3", run: nil, payload: nil)

    assert_equal 502, status
    assert_equal "epb_test_rails", body[:app]
    assert_equal 3, body[:hops_received]
    assert_equal "downstream_failed", body[:error]
    assert_equal 403, body[:downstream_status]
    assert_includes body[:downstream_error], "endpoint not granted"
    assert_equal 1, peer.calls.length, "a failure is still exactly one downstream call"
  end

  test "a refusal is never swallowed into a 200" do
    [ 401, 403, 404, 500, 502, 503 ].each do |downstream_status|
      peer = FailingPeer.new(status: downstream_status, error: "nope")
      status, body = relay(downstream: peer).call(hops_header: "2", run: nil, payload: nil)

      assert_equal 502, status, "downstream #{downstream_status} must not answer 200"
      assert_equal downstream_status, body[:downstream_status]
      refute body.key?(:terminated), "a failed relay is not a termination"
      refute body.key?(:downstream)
    end
  end

  test "a transport failure has no downstream status to preserve" do
    peer = FailingPeer.new(status: nil, error: "Excon::Error::Timeout: read timeout reached")
    status, body = relay(downstream: peer).call(hops_header: "1", run: nil, payload: nil)

    assert_equal 502, status
    assert_equal "downstream_failed", body[:error]
    assert_nil body[:downstream_status]
    assert_includes body[:downstream_error], "Timeout"
  end

  # --- configuration --------------------------------------------------------

  test "the app name defaults to the repository name" do
    with_env("EPB_MESH_APP_NAME" => nil) do
      assert_equal "epb_test_rails", Mesh.app_name
    end
  end

  test "the app name can be overridden by the environment" do
    with_env("EPB_MESH_APP_NAME" => "epb_test_rails_canary") do
      assert_equal "epb_test_rails_canary", Mesh.app_name
    end
  end

  test "a blank app name override falls back to the repository name" do
    with_env("EPB_MESH_APP_NAME" => "  ") do
      assert_equal "epb_test_rails", Mesh.app_name
    end
  end

  test "the downstream url comes from the environment and is blank-safe" do
    with_env("EPB_MESH_DOWNSTREAM_URL" => nil) { assert_nil Mesh.downstream_url }
    with_env("EPB_MESH_DOWNSTREAM_URL" => "") { assert_nil Mesh.downstream_url }
    with_env("EPB_MESH_DOWNSTREAM_URL" => "   ") { assert_nil Mesh.downstream_url }
    with_env("EPB_MESH_DOWNSTREAM_URL" => " #{DOWNSTREAM} ") { assert_equal DOWNSTREAM, Mesh.downstream_url }
  end
end
