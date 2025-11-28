# frozen_string_literal: true

class TeachersController < AuthenticatedController
  version ["1.0", "2.0"], only: [:index, :show]

	def index
		render json: {
			teachers: [
				{ name: "Sam Smith", num: "12" },
				{ name: "Joy Jones", num: "13" }
			]
		}
	end

  def show
    render json: {}
  end
end
