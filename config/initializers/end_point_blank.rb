require "utility/git_commit"

EndPointBlank.configure do |config|
  config.base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  config.log_base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  config.client_id = 'Sb3RaIlSXd8EvPmQnLuTwFc4YjHgNvOq'
  config.client_secret = 'vH4pQmY7dN3sLkR2tC6bXeJiW0aFzGoBMaVnQkDpEyHwIlZcSxrUfOgtXu9P1J8'
  config.log_mode = :direct
  config.application_version = Utility::GitCommit.commit_sha
end
