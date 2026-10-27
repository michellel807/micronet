# app/controllers/admin_controller.rb
class AdminController < ApplicationController
  # A per-process backstop; use an ingress limit across multiple replicas too.
  LOGIN_RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new(size: 1.megabyte)
  rate_limit to: 10, within: 3.minutes, only: :authenticate_admin,
    store: LOGIN_RATE_LIMIT_STORE,
    with: -> { render plain: "Too many login attempts. Please try again later.", status: :too_many_requests }

  before_action :require_admin, except: [:login, :authenticate_admin]

  def index
  end

  def login
    # Render the login form
  end

  def authenticate_admin
    if request.post?
      # Handle login form submission
      admin = Admin.find_by(username: params[:username])
      if admin && admin.authenticate(params[:password])
        reset_session
        session[:admin_id] = admin.id
        redirect_to admin_jobs_path
      else
        flash.now[:error] = 'Invalid username or password. Please try again.'
        puts "Incorrect login"
        render :login
      end
    else
      # Check if user is already logged in for non-POST requests
      redirect_to login_path unless current_admin
    end
  end

  def logout
    reset_session
    redirect_to login_path
  end

  def update_username
    admin = Admin.find(session[:admin_id])

    if admin&.authenticate(params[:current_password])
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

    if admin&.authenticate(params[:current_password])
      if params[:new_password].blank?
        flash[:error] = 'New password cannot be empty.'
        redirect_to admin_jobs_path
      elsif params[:new_password] != params[:password_confirmation]
        flash[:error] = 'Password confirmation does not match.'
        redirect_to admin_jobs_path
      elsif admin.update(password: params[:new_password])
        # Force logout after password change for security
        reset_session
        flash[:success] = 'Password updated successfully. Please log in with your new password.'
        redirect_to login_path
      else
        flash[:error] = admin.errors.full_messages.join(', ')
        redirect_to admin_jobs_path
      end
    else
      flash[:error] = 'Invalid current password. Please try again.'
      redirect_to admin_jobs_path
    end
  end

  private

  def require_admin
    redirect_to login_path unless current_admin
  end
end

