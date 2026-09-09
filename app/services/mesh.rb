# frozen_string_literal: true

# The hop budget, per docs/superpowers/specs/2026-09-08-hop-budget-contract.md
# in end_point_blank_deploy (sc-264).
#
# WHY THIS LIVES HERE AND NOT IN THE SDK
#
# sc-263 wires the five epb_test_* applications into a ring:
# epb_test_ex -> _java -> _js -> _py -> _rails -> back to _ex. A ring with no
# terminating rule is an infinite loop, so every request carries a budget and
# no application originates a downstream call without one.
#
# That is harness behaviour. It must NOT appear in end_point_blank_rails or
# any other product SDK: an SDK has no business knowing it is in a load test,
# and a header the product propagates in production is a different feature
# with a different threat model and a different review.
module Mesh
  # Must match the repository name -- sc-265 counts hops by reading the `app`
  # field out of the nested responses.
  DEFAULT_APP_NAME = "epb_test_rails"

  # Set by the caller on the way out, read by the receiver on the way in.
  HOPS_HEADER = "X-EPB-Test-Hops"

  # Opaque run identifier. Forwarded verbatim, never modified, never
  # generated. Reserved for sc-265.
  RUN_HEADER = "X-EPB-Test-Run"

  module_function

  # This application's name for the `app` field.
  # @return [String]
  def app_name
    ENV["EPB_MESH_APP_NAME"].to_s.strip.presence || DEFAULT_APP_NAME
  end

  # Base URL of the next application in the ring; the relay path is appended
  # by the caller.
  #
  # Read per request rather than memoised at boot: a load run may restage the
  # ring around a long-lived process, and nothing here is hot enough for an
  # ENV lookup to matter.
  #
  # @return [String, nil] nil when unset or blank. nil is NOT "stop quietly" --
  #   see Mesh::Relay, which raises on it whenever the budget is live.
  def downstream_url
    ENV["EPB_MESH_DOWNSTREAM_URL"].to_s.strip.presence
  end
end
