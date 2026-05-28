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

  def update_username
    admin = Admin.find(session[:admin_id])

    if admin.authenticate(params[:current_password])
      if params[:new_username].blank?
        flash[:error] = 'New username cannot be empty.'
      elsif admin.update(username: params[:new_username])
        flash[:success] = 'Username updated successfully.'
      else
        flash[:error] = admin.errors.full_messages.join(', ')
      end
    else
      flash[:error] = 'Invalid current password. Please try again.'
    end
    redirect_to admin_jobs_path
  end

  def update_password
    admin = Admin.find(session[:admin_id])

    if admin.authenticate(params[:current_password])
      if params[:new_password].blank?
        flash[:error] = 'New password cannot be empty.'
      elsif params[:new_password] != params[:password_confirmation]
        flash[:error] = 'Password confirmation does not match.'
      elsif admin.update(password: params[:new_password])
        flash[:success] = 'Password updated successfully.'
      else
        flash[:error] = admin.errors.full_messages.join(', ')
      end
    else
      flash[:error] = 'Invalid current password. Please try again.'
    end
    redirect_to admin_jobs_path
  end

end

