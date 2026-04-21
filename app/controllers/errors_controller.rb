# frozen_string_literal: true

class ErrorsController < AuthenticatedController
  version "1.0", only: [ :index ]

  def index
    raise StandardError, "This is a test error for error tracking."
  end
end
