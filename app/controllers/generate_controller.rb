class GenerateController < ApplicationController
 def index
   @job = Job.find(session[:current_user_id])
   @user = User.find_or_create_by(email: params[:email])
  @pool_replicates= session[:pool_replicates]
  @pool_options = session[:pool_options] || []
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

  end

  def run
   @job = Job.find(session[:current_user_id])
    @user = User.find_or_create_by(email: params[:email])
    @job.deleteoldfiles
    puts "old files deleted"
    @job.sendconfirm
    Delayed::Job.enqueue(JobAnalyzer.new(@job.id, session[:chart_types], session[:pool_replicates], session[:pool_options_string], session[:finalsubset],session[:hypothesis]))
    puts "beginning analysis"
    @job.update(status: "Job submitted")
    puts "Job status is #{@job.status}"
    
  respond_to do |format|
    format.html { redirect_to '/generate', notice: 'Email sent successfully.' }
    format.js 
    end
  end
end
