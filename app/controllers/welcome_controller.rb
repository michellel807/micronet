class WelcomeController < ApplicationController
  ANALYSIS_TYPES = %w[growth rnaseq].freeze

  def index
    @analysis_type = selected_analysis_type
  end

  def create
    @analysis_type = selected_analysis_type
    @user = User.find_or_create_by(email: job_params[:email])
    if !@user.valid?
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

    UploadWorkspace.find(session[:upload_token])&.discard!
    @workspace = UploadWorkspace.create!
    # Clear upload paths and analysis selections from the previous attempt,
    # while preserving an administrator's independent login.
    admin_id = session[:admin_id]
    reset_session
    session[:admin_id] = admin_id if admin_id
    session[:email] = @user.email
    session[:user_id] = @user.id
    session[:upload_token] = @workspace.token
    session[:analysis_type] = @analysis_type
    redirect_to(@analysis_type == "rnaseq" ? rnaseq_upload_path : upload_path)
  end

  private

  def job_params
    params.permit(:email, :analysis_type)
  end

  def selected_analysis_type
    params[:analysis_type].presence_in(ANALYSIS_TYPES) || "growth"
  end

end
