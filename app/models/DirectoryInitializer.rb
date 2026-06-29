class DirectoryInitializer
  def self.create_upload_directory(job)
<<<<<<< HEAD
    return unless job
=======
    raise ArgumentError, "job is required" if job.nil?
>>>>>>> 9c63dc349 (removed all userexpt commands)

    job.ensure_upload_directories!
  end
end
