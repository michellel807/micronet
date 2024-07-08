# app/models/admin.rb
class Admin < ApplicationRecord
  has_secure_password
  validates :username, presence: true, uniqueness: true
  def is_admin?
    true 
  end
end

