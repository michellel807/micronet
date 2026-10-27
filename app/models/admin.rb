# app/models/admin.rb
class Admin < ApplicationRecord
  has_secure_password
  validates :username, presence: true, uniqueness: true
  validates :password, length: { minimum: 12 }, if: -> { password.present? }
  def is_admin?
    true 
  end
end

