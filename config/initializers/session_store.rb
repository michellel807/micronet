Rails.application.config.session_store :cookie_store, 
  :key => '_my_app_session',
  :expire_after => nil  # nil = expires when browser closes

