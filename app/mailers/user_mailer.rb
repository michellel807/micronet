class UserMailer < ApplicationMailer
  default from: "noreply@duke.edu"
  SUBJECT_PREFIXES = { "rnaseq" => "Schmid Lab RNA-seq Analysis" }.freeze

  def processedjob_email(file_paths, job, used_tss = {}, requested_tss = Job::DEFAULT_TSS, analysis_failures = [])
    @job = job
    @hide_submission_summary = true
    @user = User.find(job.user_id)
    @file_names = file_paths.map { |fp| File.basename(fp) }
    @used_tss = used_tss || {}
    @requested_tss = requested_tss.to_s.to_i
    @requested_tss = Job::DEFAULT_TSS if @requested_tss < Job::DEFAULT_TSS
    @optimized_tss = @used_tss.select { |_analysis, info| info[:retried] }
    @analysis_failures = analysis_failures || []

    file_paths.each do |file_path|
      if File.exist?(file_path)
        attachments[File.basename(file_path)] = File.read(file_path)
      else
        logger.warn("Attachment missing: #{file_path}")
      end
    end

    mail(to: @user.email, subject: job_subject("Processed Data"))
  end

  # Sends a confirmation email with User-submitted meta data and optical density
  #   files as attachments. A Hash ID is generated for the User's email and used
  #   to create a URL that displays all the Jobs linked to that User's email. More
  #   details on the Job page can be found in app/controllers/jobs_controller.rb.
  # The email can be found under views/user_mailer/confirm_email.html.erb
  def confirm_email
    hashids = Hashids.new(ENV["HASHID_SLUG"].to_s)
    @user = User.find(params[:job].user_id)
    @hash = hashids.encode(@user.id)
    @job = params[:job]
    mail(to: @user.email, subject: job_subject("Job Submitted"))
  end


  def failedjob_email(job, exception_message)
    @job = job
    @exception_message = ERB::Util.html_escape(exception_message)
    mail(to: @job.user.email, subject: job_subject("Job Failed"))
  end

  def job_cancelled_email(job, admin_name = nil)
    @job = job
    @admin_name = admin_name || "Administrator"
    mail(to: @job.user.email, subject: job_subject("Job Cancelled"))
  end

  def failed_heatmap_email(job, exception_message)
    @job = job
    @exception_message = ERB::Util.html_escape(exception_message)
    mail(to: @job.user.email, subject: job_subject("Heatmap Generation Failed"))
  end


  def admin_email
    @job = params[:job]
    mail(to: 'hrd11@duke.edu', subject: job_subject("Job Submitted"))
  end

  def rnaseq_results_email(job, file_paths, manifest, warnings = [])
    @job = job
    @hide_submission_summary = true
    @own_footer = true # the template ends with its own sign-off
    @manifest = manifest
    @question = rnaseq_question(manifest)
    @method = rnaseq_method(manifest)
    @clustering = manifest["clustering"] if manifest["clustering"].is_a?(Hash) && manifest["clustering"]["status"] == "completed"
    @warnings = warnings
    @file_names = file_paths.map { |path| File.basename(path) }

    file_paths.each do |file_path|
      if File.exist?(file_path)
        attachments[File.basename(file_path)] = File.binread(file_path)
      else
        logger.warn("Attachment missing: #{file_path}")
      end
    end

    mail(to: job.user.email, subject: job_subject("Processed Data"))
  end

  private

  def rnaseq_question(manifest)
    contrast = manifest["contrast"]
    case manifest["experiment_type"] || (manifest["time"].present? ? (contrast ? "condition_by_time" : "time_course") : "two_condition")
    when "condition_by_time"
      "Which genes change differently over time in #{contrast['test_level']} samples compared with #{contrast['reference_level']} samples?"
    when "two_condition"
      "Which genes differ between #{contrast['test_level']} and #{contrast['reference_level']} samples?"
    else
      manifest["question"]
    end
  end

  def rnaseq_method(manifest)
    return "Wald test of the difference between #{manifest.dig('contrast', 'test_level')} and #{manifest.dig('contrast', 'reference_level')} (the reference)." unless manifest["test"] == "likelihood_ratio"
    return "Likelihood ratio test comparing models with and without a condition-by-time interaction." if manifest["contrast"]
    return "Likelihood ratio test comparing a model that includes time with an intercept-only model." if manifest["design"].to_s.match?(/reduced: ~ 1\b/)

    "Likelihood ratio test comparing models with and without time."
  end

  def job_subject(event)
    prefix = SUBJECT_PREFIXES.fetch(@job.analysis_type, "Schmid Lab Microbial Growth Model")
    "#{prefix}: #{event} [Job ##{@job.job_number}]"
  end
end
