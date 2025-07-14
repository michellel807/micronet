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
  puts "@pool_replicates is #{@pool_replicates}"
  puts "@pool_options_string is #{@pool_options_string}"
  puts "session[:pool_options_string] is #{session[:pool_options_string]}"
  puts"session[:chart_types] is #{session[:chart_types]}"
  puts "test_finalsubset is #{session[:test_finalsubset]}"
  puts "hypothesis is #{session[:hypothesis]}"
  puts "compare_parameters_pool is #{session[:compare_parameters_pool]}"
  puts "compare_finalsubset is #{session[:compare_finalsubset]}"
  puts "gp_pool_by_column is #{session[:gp_pool_by_column]}"
  puts "gp_subset_choice is #{session[:gp_subset_choice]}" 
  puts "gp_finalsubset is #{session[:gp_finalsubset]}"
  
  end

  def run
    @job = Job.find(session[:current_user_id])
    @user = User.find_or_create_by(email: params[:email])

    if @job.nil?
      flash[:alert] = "No active job found to submit."
      redirect_to root_path and return
    end

    @job.deleteoldfiles
    puts "old files deleted"
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
      session[:gp_subset_choice],
      session[:gp_finalsubset],
      session[:compare_parameters_pool],
      session[:compare_finalsubset],
    ))
    puts "beginning analysis"
    @job.update(status: "Job submitted")
    puts "Job status is #{@job.status}"
    
  respond_to do |format|
    format.html { redirect_to '/generate'}
    format.js 
    end
  end
end
