Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  root 'tops#new'
  namespace :api do
    namespace :web do
      resources :tops, only: [:create]
    end
  end
end
