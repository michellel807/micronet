class DirectoryInitializer
  def self.create_upload_directory(job)
    return unless job

    job.ensure_upload_directories!
  end
end
