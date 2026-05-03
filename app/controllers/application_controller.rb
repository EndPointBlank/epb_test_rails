class ApplicationController < ActionController::Base
  include EndPointBlank::Rails::Versioned

  protect_from_forgery with: :null_session

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
end
