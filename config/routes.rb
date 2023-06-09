Rails.application.routes.draw do
  root 'home#index'
  post '/generate_charts', to: 'home#generate_charts', as: 'generate_charts'
  post '/upload', to: 'home#upload', as: 'upload'
  get '/uploads/userexpt/figures/:filename', to: 'home#serve_image', as: 'serve_image'
end

