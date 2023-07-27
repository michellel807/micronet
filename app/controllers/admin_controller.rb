# app/controllers/admin_controller.rb
class AdminController < ApplicationController
  before_action :authenticate_admin, except: :login

  def index
  end

  def login
    # Render the login form
  end

  def authenticate_admin
    if request.post?
      admin = Admin.find_by(username: params[:username])
      if admin && admin.authenticate(params[:password])
        session[:admin_id] = admin.id
        redirect_to admin_jobs_path
      else
        flash.now[:error] = 'Invalid username or password. Please try again'
        puts "Incorrect login"
        render :login
      end
    end
  end

  def logout
    session[:admin_id] = nil
    redirect_to login_path
  end
end

