class UserMailer < ApplicationMailer
  default from: "noreply@duke.edu"
  def processedjob_email(file_paths, job)
    @user = User.find(job.user_id)
    @file_names = file_paths.map { |fp| File.basename(fp) }

    file_paths.each do |file_path|
      if File.exist?(file_path)
        attachments[File.basename(file_path)] = File.read(file_path)
      else
        logger.warn("Attachment missing: #{file_path}")
      end
    end

    mail(to: @user.email, subject: "Schmid Lab Microbial Growth Model: Processed Data")
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
    mail(to: @user.email, subject: "Schmid Lab Microbial Growth Model: Job Submitted")
  end


  def failedjob_email(job, exception_message)
    @job = job
    @exception_message = ERB::Util.html_escape(exception_message)
    mail(to: @job.user.email, subject: 'Schmid Lab Microbial Growth Model: Job Failed')
  end

  def failed_heatmap_email(job, exception_message)
    @job = job
    @exception_message = ERB::Util.html_escape(exception_message)
    mail(to: @job.user.email, subject: 'Schmid Lab Microbial Growth Model: Heatmap Generation Failed')
  end


  def admin_email
    mail(to: 'hrd11@duke.edu', subject: 'Schmid Lab Microbial Growth Model: Job Submitted')
  end
end

