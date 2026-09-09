# frozen_string_literal: true

module Mesh
  # The rule, in one place:
  #
  #   1. The caller sends X-EPB-Test-Hops: N.
  #   2. The receiver parses it into an integer n.
  #   3. If n <= 0, the receiver answers and calls nobody.
  #   4. If n > 0, the receiver makes exactly one downstream call, forwarding
  #      X-EPB-Test-Hops: n - 1, then answers.
  #
  # One entry request with budget N therefore produces exactly N downstream
  # calls and touches N + 1 applications, and load is a function of entry rate
  # and N alone.
  class Relay
    def initialize(app_name: Mesh.app_name, downstream_url: Mesh.downstream_url, downstream: Downstream.new)
      @app_name = app_name
      @downstream_url = downstream_url
      @downstream = downstream
    end

    # @param hops_header [String, nil] the raw X-EPB-Test-Hops value
    # @param path [String] the mesh path this request arrived on. Forwarded
    #   unchanged: /mesh/reports relays onto /mesh/reports, so a wrongly
    #   granted negative control keeps failing at every hop instead of turning
    #   into ordinary relay traffic. Required, and required per call rather
    #   than per instance, because it is a property of the request.
    # @param run [String, nil] the raw X-EPB-Test-Run value
    # @param payload [String, nil] the opaque payload to echo and forward
    # @return [Array(Integer, Hash)] the HTTP status and the response body
    # @raise [DownstreamNotConfiguredError] when the budget is live and no
    #   downstream target is configured
    def call(hops_header:, path:, run: nil, payload: nil)
      hops = HopBudget.parse(hops_header)

      return [ 200, terminated_body(hops, run, payload) ] if hops <= 0

      raise DownstreamNotConfiguredError.new(hops_received: hops) if @downstream_url.blank?

      response = @downstream.post(
        base_url: @downstream_url, path: path, hops: hops - 1, run: run, payload: payload
      )

      if response.ok?
        [ 200, relayed_body(hops, run, payload, response) ]
      else
        [ 502, failed_body(hops, response) ]
      end
    end

    private

    # terminated is true exactly when this application made no downstream call
    # because the budget was exhausted; downstream and hops_forwarded are then
    # null.
    def terminated_body(hops, run, payload)
      {
        app: @app_name,
        hops_received: hops,
        hops_forwarded: nil,
        terminated: true,
        run: run,
        payload: payload,
        downstream: nil
      }
    end

    # downstream nests the full response of the next application, so the chain
    # is self-describing: counting nesting depth proves the hop count without
    # instrumenting anything.
    def relayed_body(hops, run, payload, response)
      {
        app: @app_name,
        hops_received: hops,
        hops_forwarded: hops - 1,
        terminated: false,
        run: run,
        payload: payload,
        downstream: response.body
      }
    end

    # No terminated and no downstream key: a failed relay is neither a
    # termination nor a chain link, and sc-265 counts refusals rather than
    # dropping them.
    def failed_body(hops, response)
      {
        app: @app_name,
        hops_received: hops,
        error: "downstream_failed",
        downstream_status: response.status,
        downstream_error: response.error
      }
    end
  end
end
