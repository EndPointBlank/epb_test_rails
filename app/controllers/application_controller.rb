class ApplicationController < ActionController::Base
  include EndPointBlank::Rails::Versioned

  protect_from_forgery with: :null_session

  # Render JSON for any uncaught exception so the test app never returns
  # Rails's HTML debug page (the EPB ResponseWriter would otherwise log a
  # 100KB HTML blob instead of a parseable error body). Subclasses that
  # need more specific handling for a particular exception (e.g.
  # AuthenticatedController's rescue_from UnauthorizedError) override this
  # via their own, more specific rescue_from.
  rescue_from StandardError do |exception|
    Rails.logger.error(
      "[#{exception.class}] #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
    )

    render json: { error: "#{exception.class}: #{exception.message}" },
           status: :internal_server_error
  end

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
end
