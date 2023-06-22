class UserMailer < ApplicationMailer
  default from: "noreply@duke.edu"

  def welcome_email(file_names, job)
    @user = User.find(job.user_id)
    @file_names = file_names

    file_names.each do |file_name|
      file_path = Rails.root.join('private', 'uploads', 'userexpt', 'figures', file_name)
      attachments[file_name] = File.read(file_path) if File.exist?(file_path)
    end

    mail(to: @user.email, subject: "Phenom Model Processed Data")
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

    # The use of `Kernel#open` is a serious security risk.
    #mfile = open("#{Rails.root}/private/#{params[:job].metafile_url}").read
    #attachments["meta.csv"] = mfile

    #ofile = open("#{Rails.root}/private/#{params[:job].odfile_url}").read
    #attachments["od.csv"] = ofile

    mail(to: @user.email, subject: "Phenom Model Confirmation")
  end
end

