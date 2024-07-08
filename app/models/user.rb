class User < ApplicationRecord
  has_one :job

  # Requires a valid email to be created
  validates :email, presence: true
  validates :email, format: {with: URI::MailTo::EMAIL_REGEXP}
  def job_in_progress?
    job.present? && job.status == 'In Progress'
  end

end
