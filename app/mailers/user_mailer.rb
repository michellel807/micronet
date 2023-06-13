class UserMailer < ApplicationMailer
  default from: "noreply@duke.edu"

  # Sends the final email with processed results and visualization pdf as file attachments
  # The email can be found under views/user_mailer/welcome_email.html.erb
  def welcome_email(file_name)
    @user = User.find(params[:job].user_id)
    @file_name = file_name
    # The use of `Kernel#open` is a serious security risk.
    file = open(params[:job].pfile).read
    file2 = open(params[:job].vfile).read
    attachments[params[:filename]] = file
    attachments["final_visualizations.pdf"] = file2

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
    mfile = open("#{Rails.root}/public/#{params[:job].metafile_url}").read
    attachments["meta.csv"] = mfile

    ofile = open("#{Rails.root}/public/#{params[:job].odfile_url}").read
    attachments["od.csv"] = ofile

    mail(to: @user.email, subject: "Phenom Model Confirmation")
  end
end

