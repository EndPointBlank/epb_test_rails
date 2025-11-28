EndPointBlank.configure do |config|
  config.authorize_url = 'http://localhost:4000/api/authorize'
  config.client_id = 'osTrL1bXNdhyeelqqtY99LRfniw+EUBU'
  config.client_secret = 'jXj+sWZRqeNtVuZO4W/2l1ExfxaCon/qQAvWf6172qtjyt++l3gXZSDIkOE6b5Lk'
  config.endpoint_update_url = 'http://localhost:4000/api/applications'
  config.log_mode = :direct
  config.log_url = 'http://localhost:4000/api/logs'
  config.version = -> { '1.0.0' }
end
