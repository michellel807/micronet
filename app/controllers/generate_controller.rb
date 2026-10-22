class GenerateController < ApplicationController
 def index
  @job = Job.find(session[:current_user_id])
  @user = User.find_or_create_by(email: params[:email])
  @pool_replicates= session[:pool_replicates]
  @pool_options = session[:pool_options] || []
  @compare_parameters_pool = session[:compare_parameters_pool]
  if !@pool_options.empty?
    @pool_options_string = "'#{ @pool_options.join(",") }'"
  end
  session[:pool_options_string] = @pool_options_string
  logger.debug "@pool_replicates is #{@pool_replicates}"
  logger.debug "@pool_options_string is #{@pool_options_string}"
  logger.debug "session[:pool_options_string] is #{session[:pool_options_string]}"
  logger.debug "session[:chart_types] is #{session[:chart_types]}"
  logger.debug "test_finalsubset is #{session[:test_finalsubset]}"
  logger.debug "hypothesis is #{session[:hypothesis]}"
  logger.debug "compare_parameters_pool is #{session[:compare_parameters_pool]}"
  logger.debug "compare_finalsubset is #{session[:compare_finalsubset]}"
  logger.debug "gp_pool_by_column is #{session[:gp_pool_by_column]}"
  logger.debug "gp_subset_choice is #{session[:gp_subset_choice]}"
  logger.debug "gp_finalsubset is #{session[:gp_finalsubset]}"
  logger.debug "heatmap_value is #{session[:heatmap_value]}"
  logger.debug "heatmap_x is #{session[:heatmap_x]}"
  logger.debug "heatmap_y is #{session[:heatmap_y]}"
  
  end

  def run
    @job = Job.find(session[:current_user_id])
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

    @user = User.find_or_create_by(email: params[:email])

    if @job.nil?
      flash[:alert] = "No active job found to submit."
      redirect_to root_path and return
    end

    @job.update!(submission_options: SubmissionSummary.from_session(session))
    @job.deleteoldfiles
    logger.debug "old files deleted"
    @job.sendconfirm
    @job.sendadmin

    Delayed::Job.enqueue(JobAnalyzer.new(
      @job.id,
      session[:chart_types],
      session[:pool_replicates],
      session[:pool_options_string],
      session[:test_finalsubset],
      session[:hypothesis],
      session[:gp_pool_by_column],
      nil, # Legacy gp_subset_choice slot in serialized JobAnalyzer jobs.
      session[:gp_finalsubset],
      session[:compare_parameters_pool],
      session[:compare_finalsubset],
      session[:heatmap_value],
      session[:heatmap_x],
      session[:heatmap_y],
      session[:gp_time_step_size] || Job::DEFAULT_TSS
    ))
    Rails.logger.info("GenerateController#run enqueued JobAnalyzer job_id=#{@job.id}")
    logger.debug "beginning analysis"
    @job.update(status: "Job submitted")
    logger.debug "Job status is #{@job.status}"
    
  respond_to do |format|
    format.html { redirect_to '/generate'}
    format.js 
    end
  end
end
