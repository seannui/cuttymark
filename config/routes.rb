Rails.application.routes.draw do
  # Mission Control for job monitoring
  mount MissionControl::Jobs::Engine, at: "/jobs"

  # Projects
  resources :projects

  # Videos
  resources :videos do
    member do
      post :transcribe
      post :reprocess
    end
  end

  # Search
  resources :search_queries, path: "search"

  # Clips
  resources :clips do
    member do
      post :render_clip
    end
    resource :export, only: [:create]
  end

  # Batch exports
  resources :exports, only: [:new] do
    collection do
      post :batch
    end
  end

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Root
  root "projects#index"
end
