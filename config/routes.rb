Rails.application.routes.draw do
  resources :feedbacks

  # Other routes

  get "/", to: "welcome#index"
  post "/", to: "welcome#create"
  root 'welcome#index'
  delete '/upload/delete_files', to: 'upload#delete_files'
  get '/upload', to: 'upload#index'
  get '/selectanalyses', to: 'selectanalyses#index'
  post '/selectanalyses', to: 'selectanalyses#index'
  get '/review', to: 'review#index'
  post '/review', to: 'review#index'
  get '/generate', to: 'generate#index'
  post '/generate', to: 'generate#run'
  post '/upload', to: 'upload#upload'
  get '/uploads/jobs/:job_id/figures/:filename', to: 'files#serve_image', as: 'serve_job_image', format: false, constraints: { filename: /[^\/]+/ }
  get '/jobs/:job_id/downloads/figures/:filename', to: 'files#download', as: 'download_job_figure', format: false, constraints: { filename: /[^\/]+/ }
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
    get 'login', to: 'admin#login', as: :login
    post 'authenticate', to: 'admin#authenticate_admin', as: 'authenticate_admin'
    # Dispatch target for admin_logout_path (namespace helper below); keep.
    delete 'logout', to: 'admin#logout'
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
