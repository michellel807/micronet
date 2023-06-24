class WelcomeController < ApplicationController
  def index
    @user = User.find_by(email: params[:email])
    if @user && @user.job && @user.job.status == "Uploading Data"
      flash.now[:notice] = "Looks like you have an unsaved job open. Would you like to resume?"
    end
  end

  def create
    @user = User.find_or_create_by(email: job_params[:email])

    if !@user.valid? # ensures email matches email format
      @user.destroy
      flash.now.notice = "Invalid Email"
      render "index"
      return
    end

    if @user.job_in_progress?
      # Handle the case where there is already an in-progress job for the user
      # You can display a message or redirect to a different page
      # For simplicity, we'll display a flash notice in this example
      flash.now.notice = "Looks like you have an unsaved job open. Would you like to resume?"
      session[:session_user] = @user
      render "index"
    else
      @job = Job.create(user_id: @user.id, status: "Uploading Data")
      @job.save
      session[:current_user_id] = @job.id
      puts "Job ID is #{@job.id}"
      redirect_to "/upload"
    end

  end

  def resume_job
    @user = session[:session_user]
    if @user && @user.job && @user.job.status == "Uploading Data"
      session[:current_user_id] = @user.job.id
      redirect_to "/upload"
    end
  end


  def create_job
    @job = Job.create(user_id: @user.id, status: "Uploading Data")
    @job.save
    session[:current_user_id] = @job.id
    @user.job_in_progress?
    puts "Job ID is #{@job.id}"
    redirect_to "/upload"
  end
  
  private

  def job_params
    params.permit(:email, :status, :authenticity_token, :commit)
  end

end