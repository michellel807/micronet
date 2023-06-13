class AdminController < ApplicationController
  # Renders views/admin/index.html.erb
  def index
    @jobs = Job.all
    @feedbacks = Feedback.all
    @feedbackcnt = Feedback.all.count
  end

  # Renders views/admin/feedback.html.erb
  def feedback
    @jobs = Job.all
  end

  # Renders views/admin/users.html.erb
  def users
    @users = User.all
  end

  # Renders views/admin/jobs.html.erb
  def jobs
    @jobs = Job.all

  end

end
