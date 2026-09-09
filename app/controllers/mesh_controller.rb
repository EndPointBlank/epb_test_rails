# frozen_string_literal: true

# The two mesh endpoints from the hop-budget contract (sc-264).
#
#   POST /mesh/relay    -- the `core` API package. Granted to the client
#                          organization; this is the mesh call.
#   POST /mesh/reports  -- the `reports` API package. The negative control,
#                          deliberately NOT granted, so that a refusal can be
#                          observed. Identical behaviour if it is ever reached.
#
# THE PATH IS PRESERVED ACROSS HOPS. Whichever of the two a request arrives
# on, the downstream call is made onto that same path -- reports relays to
# reports, relay relays to relay.
#
# That matters for the negative control specifically. If `reports` is wrongly
# granted at hop one, forwarding it onto /mesh/relay would convert a
# provisioning error into ordinary successful relay traffic and the whole run
# would look clean. Preserving the path keeps it failing, and loud, at every
# hop. The path comes from Mesh::PATHS, which is also what registers the
# routes, so the two cannot disagree.
#
# Both inherit AuthenticatedController, so both sit behind exactly the same
# EndPointBlank authorization as the demo CRUD routes. Exercising that
# authorization is the point; an unprotected relay endpoint would prove
# nothing.
class MeshController < AuthenticatedController
  version [ "1" ], only: [ :relay, :reports ]

  rescue_from Mesh::DownstreamNotConfiguredError do |error|
    # Loud in the log as well as in the response: a load run reading only
    # status codes must still be able to find this in the box's logs.
    Rails.logger.error("[mesh] #{error.message}")

    render json: {
      app: Mesh.app_name,
      hops_received: error.hops_received,
      error: "downstream_not_configured",
      message: error.message
    }, status: :internal_server_error
  end

  def relay
    render_relay
  end

  def reports
    render_relay
  end

  private

  def render_relay
    status, body = Mesh::Relay.new.call(
      hops_header: request.headers[Mesh::HOPS_HEADER],
      path: Mesh.path_for(action_name),
      run: request.headers[Mesh::RUN_HEADER],
      payload: payload_param
    )

    render json: body, status: status
  end

  # The contract calls payload an opaque string, echoed back. Anything that is
  # not a string is echoed as null rather than reflected in some other shape,
  # so the response stays the documented type whatever a load driver sends.
  def payload_param
    value = params[:payload]
    value.is_a?(String) ? value : nil
  end
end
