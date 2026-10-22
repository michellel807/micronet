class JobSubmission
  class InvalidUploads < StandardError; end
  class LimitReached < StandardError; end

  def self.call(user:, workspace:, choices:)
    promoted_root = nil
    created = false
    job = nil

    user.with_lock do
      job = user.jobs.find_by(upload_token: workspace.token)
      next if job # A retry of the same submission must not queue it again.
      raise LimitReached unless Job.can_user_submit?(user.id)

      workspace.with_lock do
        data = Array(choices[:data_file_paths])
        mappings = Array(choices[:mapping_file_paths])
        valid_paths = data.any? && data.length == mappings.length &&
          data.all? { |path| valid_input?(path, workspace.data_dir) } &&
          mappings.all? { |path| valid_input?(path, workspace.mapping_dir) }
        raise InvalidUploads unless valid_paths

        job = user.jobs.create!(
          status: "Job submitted", confirm_time: Time.current,
          upload_token: workspace.token,
          submission_options: SubmissionSummary.from_session(choices)
        )
        FileUtils.mkdir_p(job.upload_root.parent)
        destination = job.upload_root
        FileUtils.mv(workspace.upload_root, destination)
        promoted_root = destination
        job.ensure_upload_directories!
        if job.pair_metadata_path.file?
          metadata = JSON.parse(job.pair_metadata_path.read)
          metadata["job_id"] = job.id
          job.pair_metadata_path.write(JSON.pretty_generate(metadata))
        end

        pool_options = choices[:pool_replicates] == "yes" ? Array(choices[:pool_options]).join(",") : nil
        Delayed::Job.enqueue(JobAnalyzer.new(
          job.id, choices[:chart_types], choices[:pool_replicates], pool_options,
          choices[:test_finalsubset], choices[:hypothesis], choices[:gp_pool_by_column],
          nil, choices[:gp_finalsubset], choices[:compare_parameters_pool], choices[:compare_finalsubset],
          choices[:heatmap_value], choices[:heatmap_x], choices[:heatmap_y],
          choices[:gp_time_step_size] || Job::DEFAULT_TSS
        ))
        created = true
      end
    end
    [job, created]
  rescue StandardError
    # Filesystem moves are not covered by the database transaction. Restore
    # the inputs if creating or enqueueing the job fails, so users can retry.
    if promoted_root && promoted_root.directory? && !workspace.upload_root.exist?
      FileUtils.mv(promoted_root, workspace.upload_root)
      if workspace.pair_metadata_path.file?
        metadata = JSON.parse(workspace.pair_metadata_path.read)
        metadata.delete("job_id")
        workspace.pair_metadata_path.write(JSON.pretty_generate(metadata))
      end
    end
    raise
  end

  def self.valid_input?(path, directory)
    path.present? && File.file?(path) && Pathname.new(path).realpath.to_s.start_with?(directory.realpath.to_s + File::SEPARATOR)
  rescue Errno::ENOENT
    false
  end
  private_class_method :valid_input?
end
