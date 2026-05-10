require "utility/git_commit"

EndPointBlank.configure do |config|
  config.base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  config.log_base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  config.client_id = '1HPEaP4lT1V6iX4gk1bYojP+ts4D+kXy'
  config.client_secret = 'etAkAUNu+9SxUst0ifRQP8udSG0eA/gDP4mjJyrNYZv5j8yYGJ2q+Q2+Hocm2yKX'
  config.log_mode = :direct
  config.application_version = Utility::GitCommit.commit_sha
end
