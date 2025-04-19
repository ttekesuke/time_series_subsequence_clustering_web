Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  root to: 'time_series#index'
  mount ActionCable.server => '/cable'
  get 'time_series/index'
  namespace :api do
    namespace :web do
      namespace :time_series do
        post 'analyse'
        post 'generate'
      end
    end
  end
end
