module RnaSeq
  # Runs one RNA-seq job. Each stage reads only files written by earlier stages
  # in Job#rnaseq_results_dir. A failed required stage fails the job; a failed
  # optional stage is reported as a warning beside the completed results.
  # Later stages (clustering, Gaussian process trajectories) are added to #stages.
  class Pipeline
    SCRIPTS = Rails.root.join("lib", "scripts", "rnaseq")
    Stage = Struct.new(:name, :required, :action)
    # Duke's SMTP attachment limit is unconfirmed; larger results are trimmed.
    DEFAULT_ATTACHMENT_LIMIT_MB = 20

    attr_reader :job, :warnings, :manifest

    def initialize(job)
      @job = job
      @warnings = []
    end

    def run
      if job.cancelled?
        log("is already cancelled; skipping analysis.")
        return
      end
      @configuration = Configuration.from_h(job.analysis_config)
      return unless start!

      FileUtils.rm_rf(job.rnaseq_results_dir)
      FileUtils.mkdir_p(job.rnaseq_results_dir)
      stages.each { |stage| run_stage(stage) }
      finish!
    rescue Job::Cancelled
      log("was cancelled; stopping without a failure notification.")
    rescue => e
      fail!(e)
    end

    def stages
      [
        Stage.new("Differential expression", true, :differential_expression),
        Stage.new("Plots", false, :plots),
        Stage.new("Packaging", true, :package)
      ]
    end

    def zip_path
      job.upload_root.join("rnaseq", "rnaseq_results_job#{job.job_number}.zip")
    end

    def attachment_limit_bytes
      ENV.fetch("RNASEQ_ATTACHMENT_LIMIT_MB", DEFAULT_ATTACHMENT_LIMIT_MB).to_f * 1024 * 1024
    end

    private

    def run_stage(stage)
      raise Job::Cancelled, "Job #{job.id} was cancelled." if job.cancelled?

      log("starting #{stage.name}.")
      send(stage.action)
    rescue Job::Cancelled
      raise
    rescue => e
      raise if stage.required

      Rails.logger.error("[RNA-seq job #{job.id}] #{stage.name} failed: #{e.message}")
      warnings << { analysis: stage.name, message: e.message }
    end

    def differential_expression
      config_path = job.upload_root.join("rnaseq", "deseq2_config.json")
      @configuration.write_deseq2_config(config_path)
      succeeded = RScript.exec(
        SCRIPTS.join("deseq2_analysis.R"),
        "--counts", job.rnaseq_input_dir.join(@configuration.counts_file),
        "--metadata", job.rnaseq_input_dir.join(@configuration.metadata_file),
        "--config", config_path,
        "--out", job.rnaseq_results_dir
      ) { |*command| job.run_cancellable_command(*command) }
      memory_failure = !succeeded && memory_failure?
      @manifest = read_manifest
      return if succeeded && manifest&.dig("status") == "completed"

      if memory_failure
        raise "The differential expression analysis ran out of memory. Please contact us at schmidlabmodel@gmail.com about analyzing a dataset of this size."
      elsif manifest&.dig("error_type") == "input_error"
        raise "Your RNA-seq files could not be analyzed: #{manifest['message']}"
      elsif manifest&.dig("status") == "failed"
        raise "The differential expression analysis stopped unexpectedly: #{manifest['message']}"
      else
        raise "The differential expression analysis did not finish."
      end
    end

    def plots
      succeeded = Python.exec(SCRIPTS.join("plot_results.py"), job.rnaseq_results_dir) { |*command| job.run_cancellable_command(*command) }
      raise "The plots could not be drawn. The result tables are complete." unless succeeded
    end

    def package
      succeeded = Python.exec(
        SCRIPTS.join("package_results.py"), job.rnaseq_results_dir, zip_path, "--job-number", job.job_number
      ) { |*command| job.run_cancellable_command(*command) }
      raise "The results could not be packaged." unless succeeded && zip_path.file?
    end

    def finish!
      attachments = email_attachments
      status = warnings.present? ? "Completed with warnings" : "Completed"
      return unless transition_from_active(status, end_time: Time.current)

      UserMailer.rnaseq_results_email(job, attachments, manifest, warnings).deliver_now
    end

    # The zip holds everything. If it is too large to email, send the summary
    # files and plots instead and say so.
    def email_attachments
      return [zip_path] if zip_path.size <= attachment_limit_bytes

      warnings << {
        analysis: "Email attachment size",
        message: "The full results (#{(zip_path.size / 1024.0 / 1024).round(1)} MB) are too large to email, " \
                 "so only the significant genes, plots and README are attached. " \
                 "Contact schmidlabmodel@gmail.com for the complete files."
      }
      %w[README.txt significant_genes.tsv pca.pdf ma_plot.pdf volcano_plot.pdf top_gene_trajectories.pdf]
        .map { |name| job.rnaseq_results_dir.join(name) }.select(&:file?)
    end

    def fail!(error)
      Rails.logger.error("[RNA-seq job #{job.id}] failed: #{error.class}: #{error.message}")
      if transition_from_active("Failed", end_time: Time.current)
        UserMailer.failedjob_email(job, error.message).deliver_now
      else
        log("is no longer active; skipping failure notification.")
      end
    end

    def start!
      return true if transition_from_active("Analyzing...", start_time: Time.current)

      log("is no longer active; skipping analysis.")
      false
    end

    # Status changes apply only while the job is still queued or running, so an
    # administrator's cancellation is never overwritten.
    def transition_from_active(status, **times)
      changed = Job.where(id: job.id, status: Job::ACTIVE_STATUSES)
        .update_all(status: status, updated_at: Time.current, **times)
      job.reload
      changed.positive?
    end

    def read_manifest
      path = job.rnaseq_results_dir.join("manifest.json")
      JSON.parse(path.read) if path.file?
    rescue JSON::ParserError
      nil
    end

    def memory_failure?
      Job::MEMORY_FAILURE_EXIT_CODES.include?($?&.exitstatus) || $?&.signaled?
    end

    def log(message)
      Rails.logger.info("[RNA-seq job #{job.id}] #{message}")
    end
  end
end
