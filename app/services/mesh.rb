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

  # The mesh endpoints, keyed by the MeshController action that serves them.
  #
  # THIS IS THE SINGLE DEFINITION. config/routes.rb registers exactly these
  # paths and MeshController forwards onto exactly the one the request arrived
  # on, so the route this application answers and the path it calls downstream
  # cannot drift apart. Changing a path here changes both at once; there is
  # nowhere else to forget.
  #
  # The mount point is part of the wire contract. Because the forwarded path
  # must EQUAL the inbound path, these are absolute and rooted: an engine at
  # /api/mesh or any other prefix would make the next hop 404.
  PATHS = {
    "relay" => "/mesh/relay",
    "reports" => "/mesh/reports"
  }.freeze

  module_function

  # The path this application serves -- and therefore forwards onto -- for a
  # given controller action.
  #
  # Deliberately not request.path: a format suffix (/mesh/relay.json), a
  # proxy rewrite or a stray trailing slash would all be "the path it arrived
  # on" and none of them is a path the next hop's router has. The action is
  # the thing the router actually resolved, so it is what the next hop is
  # asked for.
  #
  # @param action [String, Symbol] the controller action
  # @return [String]
  # @raise [KeyError] for an action that is not a mesh endpoint
  def path_for(action)
    PATHS.fetch(action.to_s)
  end

  # This application's name for the `app` field.
  # @return [String]
  def app_name
    ENV["EPB_MESH_APP_NAME"].to_s.strip.presence || DEFAULT_APP_NAME
  end

  # Base URL of the next application in the ring; the path the request
  # arrived on is appended by the caller -- see PATHS and the preserved-path
  # rule.
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
