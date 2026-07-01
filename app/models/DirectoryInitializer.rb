class DirectoryInitializer
  def self.create_upload_directory(job)
    raise ArgumentError, "job is required" if job.nil?

    job.ensure_upload_directories!
  end
end
