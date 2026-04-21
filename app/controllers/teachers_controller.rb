# frozen_string_literal: true

require 'debug'

class TeachersController < AuthenticatedController
  version ["2.0"], only: [:index, :show], state: "In Development"
  version ["1.0"], only: [:index, :show], state: "Current"

	def index
    EndPointBlank::Writers::LogWriter.info("Fetching teachers list (2)")
		render json: {
			teachers: [
				{ name: "Sam Smith", num: "12" },
				{ name: "Joy Jones", num: "13" }
			]
		}
  rescue => e
    debugger
	end

  def show
    render json: {}
  end
end
