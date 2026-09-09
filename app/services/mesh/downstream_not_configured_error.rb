# frozen_string_literal: true

module Mesh
  # Raised when the budget is live (n > 0) and no downstream target is
  # configured.
  #
  # This is deliberately NOT a quiet stop. Stopping because the budget ran out
  # and stopping because nothing is wired are different events: a silent stop
  # makes a broken mesh look like a working one that simply terminated, and a
  # load run against it would report clean numbers for traffic that never
  # happened.
  class DownstreamNotConfiguredError < StandardError
    # The budget that was live when the target turned out to be missing --
    # carried on the exception so the rendered 500 can report it without the
    # controller having to stash it in an instance variable first.
    attr_reader :hops_received

    def initialize(hops_received:)
      @hops_received = hops_received
      super(
        "EPB_MESH_DOWNSTREAM_URL is not configured, but this request arrived with a " \
        "hop budget of #{hops_received}. Refusing to answer as if the budget were " \
        "exhausted: that would make an unwired mesh indistinguishable from a working one."
      )
    end
  end
end
