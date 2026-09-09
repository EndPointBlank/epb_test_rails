# frozen_string_literal: true

module Mesh
  # WHO REFUSED, recoverable at the entry point (sc-290).
  #
  # `downstream_status` is per-hop by design: a refusal next door has to stay
  # distinguishable from one far away. The cost is that the ORIGINAL status
  # rides up nested inside `downstream_error`, and that nesting does not
  # survive depth -- every hop truncates the nested error to
  # Downstream::MAX_ERROR_LENGTH (500) characters against roughly 110
  # characters of envelope per level, so the original status is readable about
  # three hops from the entry point and is truncated away at four or more. In
  # a five-node ring with budget 4, the refusals lost that way are exactly the
  # ones on the far side.
  #
  # So a failure response carries an `origin` object as well, which is a flat
  # sibling of `downstream_error` rather than something nested inside it, and
  # therefore never truncated by depth:
  #
  #   "origin": { "app": "epb_test_rails", "status": 403,
  #               "hops_received": 2, "error": "access_denied" }
  #
  # It is SET ONCE, by the hop whose own downstream call failed -- the
  # observer, not the refuser, because the observer is the only participant
  # that reliably knows both the status it received and its own identity --
  # and then FORWARDED VERBATIM by every hop above it. sc-265 counts refusals
  # off this field and never off the nested walk.
  module Origin
    # The key the object travels under, in a downstream failure body.
    KEY = "origin"

    # `error` is a SHORT bounded reason. The truncation this whole object
    # exists to fix must not reappear inside it, so it is capped far below
    # Downstream::MAX_ERROR_LENGTH and is never itself a nested envelope.
    MAX_ERROR_LENGTH = 200

    module_function

    # The origin as seen by the hop that OBSERVED the failure.
    #
    # @param app [String] the OBSERVING application's own name
    # @param status [Integer, nil] the downstream HTTP status, or nil when
    #   there was none: a connect error, a timeout, or a refusal raised before
    #   any request left.
    # @param hops_received [Integer] the observing hop's own budget, so that
    #   the entry point derives depth as `entry_budget - origin.hops_received`
    #   without any hop having to know the entry budget.
    # @param error [String, nil] why it failed; capped here.
    # @return [Hash]
    def observed(app:, status:, hops_received:, error:)
      {
        app: app,
        status: status,
        hops_received: hops_received,
        error: cap(error)
      }
    end

    # The origin already carried by a downstream failure body, if it has one.
    #
    # Read out of the PARSED body, which is the whole point: by the time the
    # body has been truncated into `downstream_error` the object may be half a
    # brace short, and recovering it from there is the walk this replaces.
    #
    # A value that is not an object is treated as absent rather than forwarded.
    # Forwarding a malformed one verbatim would put a shape the contract does
    # not describe in front of sc-265, and the observing hop's own origin is
    # both well formed and true.
    #
    # @param body [Hash, nil] the parsed downstream response body
    # @return [Hash, nil]
    def extract(body)
      return nil unless body.is_a?(Hash)

      value = body[KEY]
      value.is_a?(Hash) ? value : nil
    end

    def cap(error)
      return nil if error.nil?

      error.to_s[0, MAX_ERROR_LENGTH]
    end
  end
end
