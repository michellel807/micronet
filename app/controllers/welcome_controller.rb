class WelcomeController < ApplicationController
  # Displays views/welcome/index.html.erb
  def index
  end

  # Creates (or finds) a User model corresponding to the email submitted,
  # creates a Job corresponding to the User, redirects to
  # controllers/uploads_controller
  def create
    @user = User.find_or_create_by(email: job_params[:email])
    if !@user.valid? # ensures email matches email format
      @user.destroy
      flash.now.notice = "Invalid Email"
      render "index"
      return
    end
    @job = Job.create(user_id: @user.id, status: "Uploading Data")
    @job.save
    session[:current_user_id] = @job.id
    redirect_to "/home"
  end

  # Displays views/welcome/resources.html.erb
  def resources
  end

  # Displays views/welcome/help.html.erb
  def help
  end

  # Displays views/welcome/privacy.html.erb
  def privacy
  end

  private

  def job_params
    params.permit(:email, :status, :authenticity_token, :commit)
  end
  
end
