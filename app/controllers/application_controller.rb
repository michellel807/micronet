class ApplicationController < ActionController::Base
    helper_method :current_admin

    def current_admin
      @current_admin ||= Admin.find_by(id: session[:admin_id]) if session[:admin_id]
    end
end
