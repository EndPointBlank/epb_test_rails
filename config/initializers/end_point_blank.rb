require "utility/git_commit"

EndPointBlank.configure do |config|
  config.base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  config.log_base_url = ENV.fetch("INTAKE_API_URL", "http://localhost:4001")
  config.client_id = 'YOScUN1M9eFWawcMN14gfu/6d0y6RlvG'
  config.client_secret = 'up3udV3drFAnjhcqUxDI0BXJ+Hr6Hd6wHwuZcQNXXpFj6RNkmTNH87E3QrH4OYrD'
  config.log_mode = :direct
  config.application_version = Utility::GitCommit.commit_sha
end
