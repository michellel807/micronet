class WelcomeController < ApplicationController
  def index
    @user = User.find_by(email: params[:email])
    @job = Job.find_by(id: session[:current_user_id])

    if @user && @job && @job.user_id == @user.id && @job.status == "In Progress"
      flash.now[:alert] = "Looks like you have an unsaved job open. Would you like to resume?"
    end
  end

  def create
    @user = User.find_or_create_by(email: job_params[:email])
    # Store the email value in the session (don't need these lines now but need them on the review page):
    session[:email] = job_params[:email]

  
    if !@user.valid? # ensures email matches email format
      @user.destroy
      flash.now.notice = "Invalid Email"
      render "index"
      return
    end

    @job = Job.find_by(user_id: @user.id, status: "In Progress")
    if @job.present? && @job.status == "In Progress"
      flash.now.alert = "Looks like you have an unsaved job open. Would you like to resume?"
      session[:session_user] = @user
      render "index"
    else
      @job = Job.create(user_id: @user.id)
      @job.save
      @job.update(status: "In Progress")
      session[:current_user_id] = @job.id
      puts "Job ID is #{@job.id}"
      puts "User is #{@user.id}"
      puts "status is #{@job.status}"
      redirect_to "/upload/delete_files"
    end

  end

  def resume_job
    @user = session[:session_user]
    @job = Job.find(session[:current_user_id])
    if @job && @job.status == "In Progress"
      puts "Redirecting to upload page: job id is #{@user.job.id}"
      redirect_to "/upload"
    else
      flash[:alert] = "No job to resume."
      redirect_to root_path
    end
  end


  def create_job
    @user = session[:session_user]
    @job = Job.create(user_id: @user.id, status: "In Progress")
    @job.save
    session[:current_user_id] = @job.id
    puts "Job ID is #{@job.id}"
    puts "User is #{@user.id}"
    puts "Job status is #{@user.job_in_progress?}"
    redirect_to "/upload/delete_files"
  end
  
  private

  def job_params
    params.permit(:email, :status, :authenticity_token, :commit)
  end

end