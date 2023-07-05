class GenerateController < ApplicationController
 def index
   @job = Job.find(session[:current_user_id])
   @user = User.find_or_create_by(email: params[:email])
  @pool_replicates= session[:pool_replicates]
  @pool_options= session[:pool_options]
   puts "@pool_replicates is #{@pool_replicates}"
   puts "@pool_options is #{@pool_options}"
   if @pool_replicates == "no"
     puts "secret status unlocked"
   end
  end

  def run
   @job = Job.find(session[:current_user_id])
    @user = User.find_or_create_by(email: params[:email])
    @job.deleteoldfiles
    puts "old files deleted"
    @job.sendconfirm
    Delayed::Job.enqueue(JobAnalyzer.new(@job.id, params[:chart_types], session[:pool_replicates], session[:pool_options]))
    puts "beginning analysis"
    @job.update(status: "Job submitted")
    puts "Job status is #{@job.status}"
    
  respond_to do |format|
    format.html { redirect_to '/generate', notice: 'Email sent successfully.' }
    format.js 
    end
  end
end
