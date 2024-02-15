Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  root 'time_series_analysis#new'
  namespace :api do
    namespace :web do
      resources :time_series_analysis, only: [:create]
    end
  end
end
