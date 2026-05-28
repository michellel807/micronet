Rails.application.routes.draw do
  resources :feedbacks
  resources :jobs

  # Other routes

  get "/", to: "welcome#index"
  post "/", to: "welcome#create"
  root 'welcome#index'
  get '/upload/delete_files', to: 'upload#delete_files'
  get '/upload', to: 'upload#index'
  post '/resume_job', to: 'welcome#resume_job', as: 'resume_job'
  post '/create_job', to: 'welcome#create_job', as: 'create_job'
  get '/selectanalyses', to: 'selectanalyses#index'
  post '/selectanalyses', to: 'selectanalyses#index'
  get '/review', to: 'review#index'
  post '/review', to: 'review#index'
  get '/generate', to: 'generate#index'
  post '/generate', to: 'generate#run'
  post '/upload', to: 'upload#upload'
  get '/uploads/userexpt/figures/:filename', to: 'home#serve_image', as: 'serve_image'
  get "/confirm", to: "confirm#index"
  post "/confirm", to: "confirm#final"
  post "/confirm/update", to: "confirm#update"
  get "/jobs/:id", to: "jobs#show"
  get '/resources', to: 'resources#index'
  get "/help", to: "help#index"
  get "/admin", to: "admin#login"
  get "/contact", to: "contacts#new"
  get '/download_data/:file_name', to: 'help#download_data_file', as: 'download_data_file'
  get '/download_mapping/:file_name', to: 'help#download_mapping_file', as: 'download_mapping_file'
  get '/download_meta/:file_name', to: 'help#download_meta_file', as: 'download_meta_file'
  get '/download_interval/:file_name', to: 'help#download_interval_file', as: 'download_interval_file'

  get '/healthcheck' => 'healthcheck#index'

  patch '/admin/update_username', to: 'admin#update_username', as: :update_admin_username
  patch '/admin/update_password', to: 'admin#update_password', as: :update_admin_password

  scope '/admin' do
    get 'login', to: 'admin#login'
    post 'authenticate', to: 'admin#authenticate_admin', as: 'authenticate_admin'
    delete 'logout', to: 'admin#logout'
    resources :jobs, module: 'admin', only: [:index, :destroy]
  end

  namespace :admin do
    delete '/logout', to: 'admin#logout', as: 'logout'
    resources :jobs, only: [:index, :destroy] do
      member do
        patch 'cancel'
      end
    end
  end

end
