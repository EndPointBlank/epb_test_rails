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

  # Written out rather than read from Mesh::PATHS: these are the paths the
  # contract names, and a test that derived them from the implementation could
  # not notice the implementation changing them.
  RELAY_PATH = "/mesh/relay"
  REPORTS_PATH = "/mesh/reports"

  # A peer that is this same application. Every call it receives is recorded,
  # then handed to a fresh Relay wired back to this same object, so N nodes of
  # the ring are simulated by one counter.
  #
  # The recorded path is fed straight back into the nested Relay, exactly as a
  # real peer's router would: a request that arrives on /mesh/reports is served
  # by the peer's reports action, which relays onto reports again. If the
  # implementation rewrote the path, this ring would show it changing at hop
  # one and staying changed.
  class RingPeer
    attr_reader :calls

    # app_name:: what each simulated node calls itself. A callable is handed
    #   that node's own budget, so a ring can give every depth a distinct
    #   identity -- which is how the origin tests tell the deep node apart from
    #   the intermediate ones rather than merely apart from the entry point.
    # deepest:: an alternative downstream for the node that makes the LAST call
    #   in the chain, i.e. the one whose own budget is 1. That is how a failure
    #   is planted at the FAR end of the ring instead of next door, which is
    #   the case `origin` exists for.
    def initialize(downstream_url: DOWNSTREAM, app_name: "epb_test_peer", deepest: nil)
      @calls = []
      @downstream_url = downstream_url
      @app_name = app_name
      @deepest = deepest
    end

    def post(base_url:, path:, hops:, run:, payload:)
      @calls << { base_url: base_url, path: path, hops: hops, run: run, payload: payload }

      status, body = Mesh::Relay.new(
        app_name: name_for(hops),
        downstream_url: @downstream_url,
        downstream: downstream_for(hops)
      ).call(hops_header: hops.to_s, path: path, run: run, payload: payload)

      # A real peer answers over HTTP, so the nested answer is mapped back
      # through EXACTLY the production mapping -- string keys, and the
      # 500-character truncation of the error that `origin` exists to survive.
      # A rig that handed the body straight back untruncated would prove the
      # opposite of what these tests claim.
      Mesh::Downstream.interpret(status, body.to_json)
    end

    private

    def name_for(hops)
      @app_name.respond_to?(:call) ? @app_name.call(hops) : @app_name
    end

    def downstream_for(hops)
      @deepest && hops == 1 ? @deepest : self
    end
  end

  # A peer that always fails, the way a refusal or an unreachable host does.
  #
  # `origin` is how it says whether the failure has ALREADY been attributed
  # deeper down: nil is a leaf refusal, and a hash is the shape a hop below
  # produces once its own downstream call has failed.
  class FailingPeer
    attr_reader :calls

    def initialize(status:, error:, origin: nil)
      @status = status
      @error = error
      @origin = origin
      @calls = []
    end

    def post(base_url:, path:, hops:, run:, payload:)
      @calls << { base_url: base_url, path: path, hops: hops, run: run, payload: payload }
      Mesh::Downstream::Response.new(status: @status, body: nil, error: @error, origin: @origin)
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
      relay(downstream: peer).call(hops_header: budget.to_s, path: RELAY_PATH, run: nil, payload: nil)

      assert_equal budget, peer.calls.length,
        "budget #{budget} should make exactly #{budget} downstream calls"
    end
  end

  test "a budget of N touches N+1 applications, one deeper per hop" do
    status, body = relay(downstream: RingPeer.new).call(hops_header: "4", path: RELAY_PATH, run: nil, payload: nil)

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
    relay(downstream: peer).call(hops_header: "5", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal [ 4, 3, 2, 1, 0 ], peer.calls.map { |c| c[:hops] }
  end

  test "a clamped budget still terminates, at the clamp" do
    peer = RingPeer.new
    relay(downstream: peer).call(hops_header: "1000000", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal Mesh::HopBudget::MAX, peer.calls.length
  end

  # --- the path is preserved across hops ------------------------------------

  test "the path a request arrived on is the path it is forwarded onto" do
    [ RELAY_PATH, REPORTS_PATH ].each do |path|
      peer = RingPeer.new
      relay(downstream: peer).call(hops_header: "1", path: path, run: nil, payload: nil)

      assert_equal [ path ], peer.calls.map { |c| c[:path] },
        "a request on #{path} must be forwarded onto #{path}"
    end
  end

  test "the path is preserved at every hop, not only the first" do
    # This is the whole reason for the rule. /mesh/reports is a negative
    # control on an API package sc-263 deliberately does not grant. If a hop
    # rewrote it onto /mesh/relay, a reports request that was WRONGLY granted
    # at hop one would turn into ordinary successful relay traffic from hop two
    # onward and the run would look clean. Preserving it keeps the wrongly
    # granted call hitting reports, and failing, at every hop.
    [ RELAY_PATH, REPORTS_PATH ].each do |path|
      peer = RingPeer.new
      relay(downstream: peer).call(hops_header: "4", path: path, run: nil, payload: nil)

      assert_equal [ path ] * 4, peer.calls.map { |c| c[:path] },
        "#{path} must survive all four hops unchanged"
    end
  end

  test "the two paths do not bleed into one another" do
    relay_peer = RingPeer.new
    reports_peer = RingPeer.new

    relay(downstream: relay_peer).call(hops_header: "3", path: RELAY_PATH, run: nil, payload: nil)
    relay(downstream: reports_peer).call(hops_header: "3", path: REPORTS_PATH, run: nil, payload: nil)

    refute_includes relay_peer.calls.map { |c| c[:path] }, REPORTS_PATH
    refute_includes reports_peer.calls.map { |c| c[:path] }, RELAY_PATH
  end

  # --- the terminating answer ----------------------------------------------

  test "an exhausted budget answers and calls nobody" do
    status, body = relay(downstream: ForbiddenPeer.new).call(
      hops_header: "0", path: RELAY_PATH, run: "run-1", payload: "hello"
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
      status, body = relay(downstream: ForbiddenPeer.new).call(hops_header: raw, path: RELAY_PATH, run: nil, payload: nil)

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
      hops_header: "0", path: RELAY_PATH, run: nil, payload: nil
    )

    assert_equal 200, status
    assert_equal true, body[:terminated]
  end

  # --- the successful relay -------------------------------------------------

  test "a live budget nests the downstream response verbatim" do
    peer = RingPeer.new
    status, body = relay(downstream: peer).call(hops_header: "2", path: RELAY_PATH, run: "run-9", payload: "p")

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
    _status, body = relay(downstream: peer).call(hops_header: "3", path: RELAY_PATH, run: "  Run/ID:7  ", payload: nil)

    assert_equal [ "  Run/ID:7  " ] * 3, peer.calls.map { |c| c[:run] }
    assert_equal "  Run/ID:7  ", body[:run]
  end

  test "an absent run identifier stays absent and is not invented" do
    peer = RingPeer.new
    _status, body = relay(downstream: peer).call(hops_header: "2", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal [ nil, nil ], peer.calls.map { |c| c[:run] }
    assert_nil body[:run]
  end

  test "the payload is echoed and forwarded" do
    peer = RingPeer.new
    _status, body = relay(downstream: peer).call(hops_header: "1", path: RELAY_PATH, run: nil, payload: "opaque")

    assert_equal [ "opaque" ], peer.calls.map { |c| c[:payload] }
    assert_equal "opaque", body[:payload]
    assert_equal "opaque", body[:downstream]["payload"]
  end

  # --- misconfiguration is loud --------------------------------------------

  test "a live budget with no downstream configured raises rather than stopping quietly" do
    error = assert_raises(Mesh::DownstreamNotConfiguredError) do
      relay(downstream: ForbiddenPeer.new, downstream_url: nil).call(
        hops_header: "3", path: RELAY_PATH, run: nil, payload: nil
      )
    end

    assert_equal 3, error.hops_received
    assert_includes error.message, "EPB_MESH_DOWNSTREAM_URL"
  end

  test "a blank downstream url counts as unconfigured" do
    [ "", "   " ].each do |blank|
      assert_raises(Mesh::DownstreamNotConfiguredError) do
        relay(downstream: ForbiddenPeer.new, downstream_url: blank).call(
          hops_header: "1", path: RELAY_PATH, run: nil, payload: nil
        )
      end
    end
  end

  # --- downstream failure ---------------------------------------------------

  test "a downstream refusal becomes a 502 that preserves the status" do
    peer = FailingPeer.new(status: 403, error: "Authorization failed: endpoint not granted")
    status, body = relay(downstream: peer).call(hops_header: "3", path: RELAY_PATH, run: nil, payload: nil)

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
      status, body = relay(downstream: peer).call(hops_header: "2", path: RELAY_PATH, run: nil, payload: nil)

      assert_equal 502, status, "downstream #{downstream_status} must not answer 200"
      assert_equal downstream_status, body[:downstream_status]
      refute body.key?(:terminated), "a failed relay is not a termination"
      refute body.key?(:downstream)
    end
  end

  test "a transport failure has no downstream status to preserve" do
    peer = FailingPeer.new(status: nil, error: "Excon::Error::Timeout: read timeout reached")
    status, body = relay(downstream: peer).call(hops_header: "1", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal 502, status
    assert_equal "downstream_failed", body[:error]
    assert_nil body[:downstream_status]
    assert_includes body[:downstream_error], "Timeout"
  end

  # --- origin: who refused, recoverable at the entry point (sc-290) ---------

  # The origin an already-attributed downstream failure arrives with. String
  # keys, because it comes off the wire as parsed JSON, and one key this
  # application has never heard of, because "verbatim" has to mean the whole
  # object and not the four fields today's contract lists.
  DEEP_ORIGIN = {
    "app" => "epb_test_py",
    "status" => 403,
    "hops_received" => 1,
    "error" => "access_denied",
    "observed_at" => "2026-09-09T00:00:00Z"
  }.freeze

  test "the hop whose own downstream call failed sets the origin, with its own name and budget" do
    peer = FailingPeer.new(status: 403, error: "Authorization failed: endpoint not granted")
    _status, body = relay(downstream: peer).call(hops_header: "2", path: RELAY_PATH, run: nil, payload: nil)

    # The observer, not the refuser: this application is the only participant
    # that reliably knows both the status it received and its own identity.
    assert_equal "epb_test_rails", body[:origin][:app]
    assert_equal 403, body[:origin][:status]
    assert_equal 2, body[:origin][:hops_received], "the OBSERVING hop's own budget"
    assert_includes body[:origin][:error], "endpoint not granted"
  end

  test "an origin arriving from downstream is forwarded verbatim and never overwritten" do
    # THE RULE MOST LIKELY TO BE GOT WRONG. Getting it wrong does not raise or
    # look broken: it rewrites a refusal that happened far away as one that
    # happened next door, and sc-265 counts refusals off this exact field. So
    # it is asserted head-on, not implied by a chain test.
    peer = FailingPeer.new(status: 502, error: "the hop below answered 502", origin: DEEP_ORIGIN)
    status, body = relay(downstream: peer).call(hops_header: "4", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal 502, status
    assert_equal DEEP_ORIGIN, body[:origin], "the whole object survives, unknown keys included"

    # Every field this application could have substituted, and did not.
    refute_equal "epb_test_rails", body[:origin]["app"], "the observer is NOT this hop"
    refute_equal 502, body[:origin]["status"], "the per-hop status must not displace the origin one"
    refute_equal 4, body[:origin]["hops_received"], "this hop's own budget is not the origin's"

    # And its own per-hop fields are untouched by the forwarding.
    assert_equal "epb_test_rails", body[:app]
    assert_equal 4, body[:hops_received]
    assert_equal 502, body[:downstream_status]
  end

  test "a chain carries the DEEPEST hop's origin all the way to the entry point" do
    # The ring, with a refusal planted at the far end: this application at
    # budget 4, three peers below it, and the last of those -- the only one
    # whose own budget is 1 -- refused. Every hop between it and here has an
    # origin to forward and must not touch it.
    refusal = "Authorization failed: endpoint not granted to this application. #{"detail " * 60}"
    peer = RingPeer.new(app_name: ->(hops) { "epb_test_peer_#{hops}" }, deepest: FailingPeer.new(status: 403, error: refusal))

    status, body = relay(downstream: peer).call(hops_header: "4", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal 502, status
    assert_equal 3, peer.calls.length, "hops 3, 2 and 1; the refusal is below all of them"

    # Per-hop, unchanged: what THIS application called answered 502.
    assert_equal 502, body[:downstream_status]

    # End-to-end: the deep node, not the one next door. Keys are normalised so
    # that a hop which substituted its own origin fails ON THE NAME rather than
    # on a key type; the verbatim-forwarding test above pins the shape.
    origin = body[:origin].transform_keys(&:to_s)
    assert_equal "epb_test_peer_1", origin["app"]
    assert_equal 403, origin["status"]
    assert_equal 1, origin["hops_received"]
    refute_equal "epb_test_peer_3", origin["app"], "the hop next door is not the origin"
    refute_equal "epb_test_rails", origin["app"], "and neither is the entry point"

    # Depth is derivable at the entry point without any hop knowing the entry
    # budget: 4 - 1 == three hops down.
    assert_equal 3, 4 - origin["hops_received"]

    # And the reason origin has to exist at all: the nested walk this replaces
    # is already destroyed at this depth. downstream_error is a truncated
    # fragment, not a document anything can read a status out of.
    assert_equal Mesh::Downstream::MAX_ERROR_LENGTH, body[:downstream_error].length
    assert_raises(JSON::ParserError) { JSON.parse(body[:downstream_error]) }
  end

  test "the origin error is capped at 200 characters" do
    peer = FailingPeer.new(status: 403, error: "x" * 5_000)
    _status, body = relay(downstream: peer).call(hops_header: "1", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal 200, Mesh::Origin::MAX_ERROR_LENGTH
    assert_equal 200, body[:origin][:error].length

    # origin bounds ITSELF. The per-hop field beside it is left exactly as the
    # downstream boundary handed it over -- Mesh::Downstream applies the wider
    # 500-character cap there, and origin takes nothing away from it.
    assert_equal 5_000, body[:downstream_error].length
  end

  test "a transport failure has a null origin status, because there is no status" do
    peer = FailingPeer.new(status: nil, error: "Excon::Error::Timeout: read timeout reached")
    _status, body = relay(downstream: peer).call(hops_header: "3", path: RELAY_PATH, run: nil, payload: nil)

    assert_equal "epb_test_rails", body[:origin][:app]
    assert_nil body[:origin][:status], "a timeout has no HTTP status to attribute"
    assert_equal 3, body[:origin][:hops_received]
    assert_includes body[:origin][:error], "Timeout"
  end

  test "a successful relay carries no origin at all" do
    # origin ADDS a field to failure responses. It must not appear on the happy
    # path, where there is nothing to attribute and a chain is still described
    # by its nesting.
    _status, body = relay(downstream: RingPeer.new).call(hops_header: "3", path: RELAY_PATH, run: nil, payload: nil)

    refute body.key?(:origin)
    refute body[:downstream].key?("origin")
  end

  test "an exhausted budget carries no origin either" do
    _status, body = relay(downstream: ForbiddenPeer.new).call(
      hops_header: "0", path: RELAY_PATH, run: nil, payload: nil
    )

    refute body.key?(:origin)
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
