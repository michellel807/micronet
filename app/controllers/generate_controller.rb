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
  puts "finalsubset is #{session[:finalsubset]}"
  puts "hypothesis is #{session[:hypothesis]}"
<<<<<<< app/controllers/generate_controller.rb
  puts "compare_parameters_pool is #{session[:compare_parameters_pool]}"
  puts "finalsubset_pooled is #{session[:finalsubset_pooled]}"
=======
  
>>>>>>> app/controllers/generate_controller.rb
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
    heatmap_params = {
      generate_heatmap: params[:generate_heatmap] || session[:generate_heatmap],
      heatmap_x: params[:heatmap_x] || session[:heatmap_x],
      heatmap_y: params[:heatmap_y] || session[:heatmap_y],
      heatmap_v: params[:heatmap_v] || session[:heatmap_v],
      heatmap_format: params[:heatmap_format] || session[:heatmap_format],
      heatmap_title: params[:heatmap_title] || session[:heatmap_title]
    }
    Delayed::Job.enqueue(JobAnalyzer.new(@job.id, session[:chart_types], session[:pool_replicates], session[:pool_options_string], session[:finalsubset],session[:hypothesis], session[:finalsubset],session[:hypothesis], session[:compare_parameters_pool], session[:finalsubset_pooled], heatmap_params))
    puts "beginning analysis"
    @job.update(status: "Job submitted")
    puts "Job status is #{@job.status}"
    
  respond_to do |format|
    format.html { redirect_to '/generate'}
    format.js 
    end
  end
end
