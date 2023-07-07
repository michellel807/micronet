Rails.application.routes.draw do
  resources :feedbacks
  resources :jobs
  get "/", to: "welcome#index"
  post "/", to: "welcome#create"
  root 'welcome#index'
  get '/upload/delete_files', to: 'upload#delete_files'
  get '/upload', to: 'upload#index'
  post '/resume_job', to: 'welcome#resume_job', as: 'resume_job'
  post '/create_job', to: 'welcome#create_job', as: 'create_job'
  get '/parameter', to: 'parameter#index'
  get '/selectanalyses', to: 'selectanalyses#index'
  post '/selectanalyses', to: 'selectanalyses#index'
  get '/generate', to: 'generate#index'
  post '/generate', to: 'generate#run'
  post '/generate_charts', to: 'home#generate_charts', as: 'generate_charts'
  post '/upload', to: 'upload#upload'
  get '/uploads/userexpt/figures/:filename', to: 'home#serve_image', as: 'serve_image'
  get "/confirm", to: "confirm#index"
  post "/confirm", to: "confirm#final"
  post "/confirm/update", to: "confirm#update"

  get "/jobs/:id", to: "jobs#show"
  get '/resources', to: 'resources#index'
  get "/help", to: "welcome#help"
end
