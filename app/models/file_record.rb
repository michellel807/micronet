# app/models/file_record.rb
class FileRecord < ApplicationRecord
  # Validations
  validates :file_path, presence: true
  validates :category, presence: true
end

