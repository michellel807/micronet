class WelcomeController < ApplicationController
  def index
    @user = User.find_by(email: params[:email])
    @job = Job.find_by(id: session[:current_user_id])

    # Only show resume prompt if there's an actual draft (In Progress status)
    if @user && @job && @job.user_id == @user.id && @job.status == "In Progress"
      flash.now[:alert] = "Looks like you have an unsaved job open. Would you like to resume?"
    end
  end

  def create
    @user = User.find_or_create_by(email: job_params[:email])
    session[:email] = job_params[:email]

    if !@user.valid?
      @user.destroy
      flash.now.notice = "Invalid Email"
      render "index"
      return
    end

    # Check if user has already submitted the max number of active jobs
    if !Job.can_user_submit?(@user.id)
      flash.now.alert = "You already have #{Job::MAX_ACTIVE_JOBS_PER_USER} jobs queued or running. Please wait for one to finish before submitting another."
      render "index"
      return
    end

    # Check for existing draft (In Progress only, not submitted)
    draft_job = Job.find_by(user_id: @user.id, status: "In Progress")
    if draft_job.present?
      flash.now.alert = "Looks like you have an unsaved job open. Would you like to resume?"
      session[:session_user] = @user
      render "index"
      return
    end

    # Create new job as draft with "In Progress" status
    @job = Job.create(user_id: @user.id, status: "In Progress")
    @job.save
    session[:current_user_id] = @job.id
    puts "Job ID is #{@job.id}"
    puts "User is #{@user.id}"
    puts "status is #{@job.status}"
    redirect_to "/upload/delete_files"
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