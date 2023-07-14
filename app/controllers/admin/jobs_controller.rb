class Admin:: JobsController < ApplicationController
  def index
    @jobs = Job.all
  end

  def show
    @job = Job.find(params[:id])
  end

  def destroy
    @job = Job.find(params[:id])
    @job.destroy
    redirect_to admin_jobs_path
  end
  
end
