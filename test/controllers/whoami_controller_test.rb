# frozen_string_literal: true

require "test_helper"

# The authenticate guard, end to end: the real router, the real
# `EndPointBlank::Rails::Authenticated` concern, the real `BasicAuthenticate`
# command, a real HTTP request over a loopback socket to a stub intake, and the
# real controller. Nothing between the guard and the wire is replaced.
#
# WHY THIS FILE EXISTS. Until now every protected route in this application sat
# behind the *authorize* guard, and the controller named `AuthenticatedController`
# includes `EndPointBlank::Rails::Authorized` -- not `Authenticated`. The naming
# made it look covered. It was not: no application in this harness had ever
# executed `EndPointBlank::Rails::Authenticated` even once, which is how it came
# to name a command the gem has never contained
# (`Commands::EndpointAuthenticate`), parse a response body before checking
# there was one, and raise its refusal through `raise Class, "message"` -- a form
# that structurally cannot carry intake's status. Three bugs on one path, none
# of them reachable from any test, because nothing called it.
#
# WHAT THE STATUS ASSERTIONS ARE FOR. 401 and 403 are different instructions to
# whoever is integrating: 401 says the credential was not accepted, go re-check
# it; 403 says the credential was fine and no grant covers this endpoint, go ask
# for one. A guard that collapses both to 401 sends half of its callers to debug
# the wrong thing, and does it silently -- the request is refused either way, so
# nothing fails and no count changes.
#
# This is the Ruby half of the same suite carried by epb_test_js,
# epb_test_java and epb_test_py (sc-307). Where it diverges from them, it is
# because the Ruby SDK genuinely differs, and the divergence is commented.
class WhoamiControllerTest < ActionDispatch::IntegrationTest
  WHOAMI_PATH = "/whoami"

  # Behind the *authorize* guard: StudentsController < AuthenticatedController,
  # which includes `EndPointBlank::Rails::Authorized`. Named here so it is plain
  # that the parity test compares two genuinely different guards rather than one
  # route twice. Reusing a real route rather than declaring a probe controller
  # is safe because both guards refuse before the action runs, so `#index`
  # never reaches the database.
  AUTHORIZE_GUARDED_PATH = "/students"

  # A fresh credential per request, so no cached decision can answer for intake.
  # `EndpointAuthorize` caches a grant per credential/route/method/version, and
  # although it caches only 201s -- and `authenticate!` deliberately caches
  # nothing at all -- the parity test drives both guards, so the guarantee has
  # to hold for the pair.
  def call(path)
    @credential = @credential.to_i + 1
    get path, headers: { "Authorization" => "Basic caller-#{@credential}" }
    response
  end

  def refusal_body(reason = "access_denied")
    { error: reason }.to_json
  end

  test "the route is behind the authenticate guard, and the lookalike is not" do
    # The Rails analogue of epb_test_java's reflection test, and the one
    # assertion here that speaks to the trap directly. `AuthenticatedController`
    # is named for a concern it does not include; if someone later "tidies" this
    # controller by making it a subclass of that one, every other test in this
    # file would keep passing while testing the authorize path twice.
    assert_includes WhoamiController.ancestors, EndPointBlank::Rails::Authenticated
    assert_not_includes AuthenticatedController.ancestors, EndPointBlank::Rails::Authenticated
    assert_includes AuthenticatedController.ancestors, EndPointBlank::Rails::Authorized
  end

  test "is served when intake accepts the credential" do
    StubIntake.serving(status: 201) do |intake|
      call(WHOAMI_PATH)

      assert_response :ok
      assert_equal true, response.parsed_body["authenticated"]
      assert_equal "end_point_blank_test", response.parsed_body["application"]
      assert_equal 1, intake.authorize_calls.size, "intake must actually be consulted"
    end
  end

  test "really does go through the authenticate path, over the network" do
    # The sc-306 regression. Before the fix the concern named
    # `EndPointBlank::Commands::EndpointAuthenticate`, a constant this gem has
    # never defined, so the `before_action` raised NameError and the request
    # never reached the network at all. Asserted as a real call recorded by a
    # real server: a guard that raises before Excon runs records nothing.
    StubIntake.serving(status: 201) do |intake|
      call(WHOAMI_PATH)

      assert_equal 1, intake.authorize_calls.size
      only = intake.authorize_calls.first
      assert_equal StubIntake::AUTHORIZE_PATH, only.path

      body = JSON.parse(only.body)
      # `http_method`, not `action`: that is the key the Ruby SDK sends, and
      # `EndpointAuthorize` sends it under the same name, which is why one stub
      # can serve both guards.
      assert_equal "GET", body["http_method"]
      assert_match(/\ABasic caller-/, body["client_auth"])
    end
  end

  test "tells intake the path it is guarding" do
    # Unlike the JS and Java SDKs, both Ruby guards resolve the endpoint the
    # same way -- `request.route_uri_pattern` with optional segments stripped --
    # so this does generalise to a route carrying variables. The other two
    # explicitly disclaim that, because their authenticate and authorize paths
    # still resolve differently.
    StubIntake.serving(status: 201) do |intake|
      call(WHOAMI_PATH)

      assert_equal WHOAMI_PATH, JSON.parse(intake.authorize_calls.first.body)["path"]
    end
  end

  test "a 403 reaches the caller as 403, not 401" do
    StubIntake.serving(status: 403, body: refusal_body) do
      call(WHOAMI_PATH)

      assert_response :forbidden
      assert_equal "Authentication failed: access_denied", response.parsed_body["error"]
    end
  end

  test "a 401 still reaches the caller as 401" do
    StubIntake.serving(status: 401, body: refusal_body("invalid_credentials")) do
      call(WHOAMI_PATH)

      assert_response :unauthorized
      assert_equal "Authentication failed: invalid_credentials", response.parsed_body["error"]
    end
  end

  test "any other status intake invents is passed through verbatim" do
    [ 400, 429, 500, 502 ].each do |status|
      StubIntake.serving(status: status, body: refusal_body("whatever intake said")) do
        call(WHOAMI_PATH)

        assert_equal status, response.status,
                     "the guard forwards intake's verdict rather than classifying it"
      end
    end
  end

  test "a status with no Rails symbol for it survives too" do
    # Nothing in intake sends 418. That is the point: the guard reports what it
    # was told rather than choosing from a list of statuses it recognises.
    # `assert_response` itself refuses a code it has no symbol for, which is the
    # opinion the guard must not share.
    StubIntake.serving(status: 418, body: refusal_body("teapot")) do
      call(WHOAMI_PATH)

      assert_equal 418, response.status
    end
  end

  test "a non-JSON refusal body still yields intake's status and its text" do
    # A WAF or load balancer in front of intake answers HTML, not JSON, and the
    # old guard called `JSON.parse` on that unconditionally. `reason_from` falls
    # back to the raw body, because the raw body is the only diagnostic there is
    # when it is not JSON.
    StubIntake.serving(status: 502, body: "<html>bad gateway</html>", content_type: "text/html") do
      call(WHOAMI_PATH)

      assert_response :bad_gateway
      assert_equal "Authentication failed: <html>bad gateway</html>",
                   response.parsed_body["error"]
    end
  end

  test "an unreachable intake reaches the caller as 503, not 401" do
    # Nothing judged this caller, so 401 would blame a credential no one looked
    # at. This is also the case the old guard could not reach: it parsed
    # `result.body` on the line ABOVE its own `if !result` check, so a nil
    # result died of NoMethodError on nil before the branch written for it.
    #
    # Status only, no message assertion -- following epb_test_py and
    # epb_test_java rather than epb_test_js. Ruby's `refusal_from` deliberately
    # omits the "Authentication failed: " prefix for this one case, because that
    # is what `authorize!` has always sent and the shared method must not change
    # what the working path produces for any input.
    StubIntake.with_base_url(StubIntake.unreachable_base_url) do
      call(WHOAMI_PATH)

      assert_response :service_unavailable
    end
  end

  test "fails closed when intake does not answer" do
    # Stated separately from the status, because these are two different
    # promises and only one of them is about which number arrives. An outage
    # must never become an open door.
    StubIntake.with_base_url(StubIntake.unreachable_base_url) do
      call(WHOAMI_PATH)

      assert_not_equal 200, response.status, "an unreachable intake let the request through"
    end
  end

  test "both guards give the caller the same status for the same refusal" do
    # The sc-307 regression proper. One intake, one answer, two routes:
    # /whoami through `authenticate!`, /students through `authorize!`. Before
    # the fix these gave a caller two different answers for one identical
    # refusal, and nothing in a pass/fail count could see it -- both guards
    # refused the request either way.
    #
    # 401 is the status the broken path accidentally got right, 403 is the one
    # it got wrong, and 429 is neither of the two statuses anyone thinks of as
    # "auth", so a guard that recognises a fixed list fails on it.
    [ 401, 403, 429 ].each do |status|
      StubIntake.serving(status: status, body: refusal_body) do
        via_authenticate = call(WHOAMI_PATH).status
        via_authorize = call(AUTHORIZE_GUARDED_PATH).status

        assert_equal status, via_authenticate, "authenticate lost intake's #{status}"
        assert_equal status, via_authorize, "authorize lost intake's #{status}"
        assert_equal via_authenticate, via_authorize,
                     "the two guards disagree about a #{status} from intake"
      end
    end
  end

  test "the two guards' refusals differ only in the word naming what was attempted" do
    StubIntake.serving(status: 403, body: refusal_body) do
      call(WHOAMI_PATH)
      authenticate = response.parsed_body["error"]

      call(AUTHORIZE_GUARDED_PATH)
      authorize = response.parsed_body["error"]

      assert_equal "Authentication failed: access_denied", authenticate
      assert_equal "Authorization failed: access_denied", authorize
    end
  end

  test "both guards answer 503 when intake cannot be reached" do
    StubIntake.with_base_url(StubIntake.unreachable_base_url) do
      via_authenticate = call(WHOAMI_PATH).status
      via_authorize = call(AUTHORIZE_GUARDED_PATH).status

      assert_equal 503, via_authenticate
      assert_equal 503, via_authorize
      assert_equal via_authenticate, via_authorize,
                   "the two guards disagreed about an intake that answered neither"
    end
  end
end
