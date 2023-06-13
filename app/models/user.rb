class User < ApplicationRecord
  has_many :jobs

  # Requires a valid email to be created
  validates :email, presence: true
  validates :email, format: {with: URI::MailTo::EMAIL_REGEXP}
end
