Rails.application.routes.draw do
  resources :feedbacks
  resources :jobs
  get "/", to: "welcome#index"
  post "/", to: "welcome#create"
  root 'welcome#index'
  get '/home', to: 'home#index'
  get '/generate', to: 'generate#index'
  post '/generate', to: 'generate#run'
  post '/generate_charts', to: 'home#generate_charts', as: 'generate_charts'
  post '/upload', to: 'home#upload', as: 'upload'
  get '/uploads/userexpt/figures/:filename', to: 'home#serve_image', as: 'serve_image'
  get "/confirm", to: "confirm#index"
  post "/confirm", to: "confirm#final"
  post "/confirm/update", to: "confirm#update"

  get "/jobs/:id", to: "jobs#show"

  get "/resources", to: "welcome#resources"
  get "/help", to: "welcome#help"
end
