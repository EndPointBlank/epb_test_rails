Rails.application.routes.draw do
  namespace :dev do
    resources :requests
  end
  resources :users
  resources :students, only: [ :index, :create, :destroy ]
  resources :staff, only: [ :index, :create, :destroy ]
  resources :errors, only: [ :index ]

  # The hop-budget mesh (sc-263 / sc-264). Both endpoints go through the same
  # EndPointBlank authorization as the routes above; /mesh/reports is the
  # negative control and is expected to be refused.
  #
  # Drawn from Mesh::PATHS rather than written out here, because the forwarded
  # path must equal the inbound path: the route this application answers and
  # the path MeshController calls downstream come from one definition and
  # cannot drift apart.
  Mesh::PATHS.each do |action, path|
    post path => "mesh##{action}"
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "status" => proc { [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] }

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
