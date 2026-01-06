# Configure Mission Control Jobs authentication
# In development, we'll skip authentication for easier access
# In production, use HTTP Basic Authentication

Rails.application.config.to_prepare do
  # Mission Control Jobs authentication configuration
  if Rails.env.development?
    # In development, disable authentication entirely
    MissionControl::Jobs.http_basic_auth_enabled = false
  else
    # In production, you should set up proper authentication
    # Example with HTTP Basic Auth:
    # MissionControl::Jobs.http_basic_auth_enabled = true
    # MissionControl::Jobs.http_basic_auth_user = ENV.fetch("MISSION_CONTROL_USERNAME", "admin")
    # MissionControl::Jobs.http_basic_auth_password = ENV.fetch("MISSION_CONTROL_PASSWORD", "password")
  end
end
