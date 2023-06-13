class AttachmentUploader < CarrierWave::Uploader::Base
  storage :file
  # Files are stored within public/uploads/job/job.id
  def store_dir
    "uploads/#{model.class.to_s.underscore}/#{model.id}"
  end
end
