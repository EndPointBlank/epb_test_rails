require "utility/git_commit"

EndPointBlank.configure do |config|
  config.base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  config.log_base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  # Staging regenerates these via Terraform random_password on every stand-up, so a
  # hardcoded literal can never match there; env must win. Literal stays as the
  # local dev fallback (seeded credentials).
  config.client_id = ENV.fetch("EPB_CLIENT_ID", "Sb3RaIlSXd8EvPmQnLuTwFc4YjHgNvOq")
  config.client_secret = ENV.fetch("EPB_CLIENT_SECRET", "vH4pQmY7dN3sLkR2tC6bXeJiW0aFzGoBMaVnQkDpEyHwIlZcSxrUfOgtXu9P1J8")
  config.log_mode = :direct
  config.application_version = Utility::GitCommit.commit_sha
end
