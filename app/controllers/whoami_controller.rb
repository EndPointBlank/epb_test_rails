# frozen_string_literal: true

# The one route in this application behind the EndPointBlank *authenticate*
# guard.
#
# READ THE NAME OF ITS SUPERCLASS CAREFULLY BEFORE MOVING THIS. Every other
# protected route here inherits `AuthenticatedController`, which despite its
# name includes `EndPointBlank::Rails::Authorized` -- the *authorize* guard.
# That naming is why this application looked like it covered both paths while
# actually covering one twice, and why the three bugs the authenticate concern
# carried (sc-306, sc-307) survived a harness of five applications. This
# controller therefore inherits `ApplicationController` directly and includes
# the authenticate concern itself; making it a subclass of
# `AuthenticatedController` would silently put it behind both guards and undo
# the point of the route.
#
# The two guards ask intake the same question at the same URL and differ in
# what they do with the answer: `authorize!` resolves the calling application
# environment and any deprecation from a granted body, `authenticate!` only
# decides whether the caller may reach the controller at all.
class WhoamiController < ApplicationController
  include EndPointBlank::Rails::Authenticated

  # DELIBERATELY NOT `version [...]`, matching the JS and Python test
  # applications, whose `/whoami` carries no version declaration either.
  # Endpoint versions belong to the authorize path, which resolves one specific
  # endpoint and can be granted per version. Authentication judges whether the
  # credential may reach the controller at all, which is not a per-version
  # question. `VersionFinder` then reports no version for this route, which is
  # the honest answer rather than a "1" invented to fill the field.
  #
  # Intake's refusal, served to the caller with the status intake actually
  # decided on -- 401 "re-check the credential" and 403 "ask for a grant" are
  # different instructions and must not arrive as the same number.
  #
  # Deliberately a second registration rather than something shared with
  # `AuthenticatedController`: the two guards reaching one identical answer is
  # what the parity test asserts, and it can only assert it if the two paths
  # are not the same object by construction.
  rescue_from ::EndPointBlank::UnauthorizedError do |error|
    render json: { error: error.message }, status: error.status || :unauthorized
  end

  # `application` / `authenticated`, the same two keys the JS, Java and Python
  # test applications answer `/whoami` with, so the five can be compared to each
  # other by a harness that does not know which one it is talking to.
  def show
    render json: {
      application: EndPointBlank::Configuration.instance.app_name,
      authenticated: true
    }
  end
end
