class User < ApplicationRecord
  has_many :jobs, dependent: :destroy

  # Requires a valid email to be created
  validates :email, presence: true
  validates :email, format: {with: URI::MailTo::EMAIL_REGEXP}

  def job_in_progress?
    jobs.exists?(status: Job::DRAFT_STATUS)
  end

  def current_draft
    jobs.where(status: Job::DRAFT_STATUS).order(created_at: :desc).first
  end
end
