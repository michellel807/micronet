class GenerateController < ApplicationController
 def index
   @job = Job.find(session[:current_user_id])
   @user = User.find_or_create_by(email: params[:email])
  end

  def run
   @job = Job.find(session[:current_user_id])
    @user = User.find_or_create_by(email: params[:email])
    @job.sendconfirm
    @job.delay.analyze(params[:chart_types])
    @job.update(status: "Job submitted")
    puts "Job status is #{@job.status}"
  respond_to do |format|
    format.html { redirect_to '/generate', notice: 'Email sent successfully.' }
    format.js 
    end
  end
end
