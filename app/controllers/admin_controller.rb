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
        flash.now[:error] = 'Invalid username or password. Please try again.'
        puts "Incorrect login"
        render :login
      end
    end
  end

  def logout
    session[:admin_id] = nil
    redirect_to login_path
  end

  def update_credentials
    admin = Admin.find(session[:admin_id])

    # Check if the submitted parameters are valid
    if admin&.authenticate(params[:current_password])
      if params[:new_username].present?
        admin.update(username: params[:new_username])
      end

      if params[:new_password].present?
        admin.update(password: params[:new_password])
      end

      flash[:success] = 'Username and/or password updated successfully.'
      redirect_to admin_jobs_path
    else
      flash[:error] = 'Invalid current password. Please try again.'
      redirect_to admin_jobs_path
    end
  end

end

