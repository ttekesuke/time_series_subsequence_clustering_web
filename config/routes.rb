Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  root 'time_series#new'
  namespace :api do
    namespace :web do
      namespace :time_series do
        post 'analysde'
        post 'generate'
      end
    end
  end
end
