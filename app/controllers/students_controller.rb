# frozen_string_literal: true

class StudentsController < AuthenticatedController
  version "1.0", only: [:index]

	def index
    EndPointBlank::Writers::LogWriter.info("Fetching students list (2)")
		render json: {
			students: [
				{ name: "Pete Daniels", num: "1241234" },
				{ name: "Jack Vigneau", num: "1241235" }
			]
		}
	end
end
