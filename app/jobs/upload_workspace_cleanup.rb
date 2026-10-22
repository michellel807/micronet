class UploadWorkspaceCleanup
  QUEUE = "upload_cleanup".freeze

  def self.schedule!
    return if Delayed::Job.where(queue: QUEUE, failed_at: nil).exists?

    Delayed::Job.enqueue(new, queue: QUEUE)
  end

  def perform
    removed = UploadWorkspace.cleanup_expired!
    # Remove unfinished records left by the previous upload architecture too.
    Job.where(status: Job::DRAFT_STATUS).where("updated_at < ?", UploadWorkspace::RETENTION.ago).find_each(&:destroy!)
    Rails.logger.info("[uploads:cleanup] removed #{removed} expired temporary workspaces")
    Delayed::Job.enqueue(self.class.new, queue: QUEUE, run_at: 1.hour.from_now)
  end
end
