class AuthenticatedController < ApplicationController
  include EndPointBlank::Rails::Authorized

  rescue_from ::EndPointBlank::UnauthorizedError do
    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
end
