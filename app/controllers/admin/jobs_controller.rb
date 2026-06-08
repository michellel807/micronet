class Admin::JobsController < ApplicationController
  before_action :check_admin
  def index
    @jobs = Job.order(created_at: :desc).limit(7)
  end

  def show
    @job = Job.find(params[:id])
  end

  def destroy
    @job = Job.find(params[:id])
    @job.destroy
    redirect_to admin_jobs_path
  end

  def cancel
    @job = Job.find(params[:id])
    admin_name = session[:admin_username] || "Administrator"
    @job.mark_cancelled(admin_name)
    redirect_to admin_jobs_path, notice: 'Job cancelled successfully.'
  end
  private

  def check_admin
    redirect_to login_path unless session[:admin_id].present?
  end
end
