class GenerateController < ApplicationController
  before_action :require_upload_workspace, only: :run

  def index
    @job = Job.find_by(id: session[:current_user_id], user_id: session[:user_id])
    redirect_to root_path unless @job
  end

  def run
    analysis_columns =
      if (Array(session[:chart_types]) & %w[heatmap_plot gp_plot]).any?
        mapping_columns(session[:mapping_file_paths])
      else
        []
      end

    unless Job.gp_configuration_complete?(
      chart_types: session[:chart_types],
      subset_column: session[:gp_subset_column],
      conditions: session[:gp_conditions],
      pool_column: session[:gp_pool_by_column],
      filters: GpConfiguration.filters(session),
      pool_columns: GpConfiguration.pool_columns(session),
      pooling: session[:gp_pool_replicates],
      columns: analysis_columns
    )
      flash[:error] = Job::GP_CONFIGURATION_ERROR
      redirect_to selectanalyses_path and return
    end

    unless Job.heatmap_configuration_complete?(
      chart_types: session[:chart_types],
      value: session[:heatmap_value],
      x: session[:heatmap_x],
      y: session[:heatmap_y],
      columns: analysis_columns
    )
      flash[:error] = "Please select a heatmap value and two different axes before continuing."
      redirect_to selectanalyses_path and return
    end

    @job, created = JobSubmission.call(user: @user, workspace: @workspace, choices: session)
    session[:current_user_id] = @job.id
    if created
      Rails.logger.info("GenerateController#run submitted job_id=#{@job.id}")
      @job.sendconfirm
      @job.sendadmin
    end

    respond_to do |format|
      format.html { redirect_to '/generate' }
      format.js { render js: "window.location = '/generate';" }
    end
  rescue JobSubmission::InvalidUploads
    redirect_to upload_path, alert: "Please upload a matching data and mapping file before submitting."
  rescue JobSubmission::LimitReached
    redirect_to root_path, alert: "You already have #{Job::MAX_ACTIVE_JOBS_PER_USER} jobs queued or running. Please wait for one to finish."
  rescue UploadWorkspace::Expired
    upload_workspace_expired
  end
end
