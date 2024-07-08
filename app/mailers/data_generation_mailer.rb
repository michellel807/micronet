class DataGenerationMailer < ApplicationMailer
  def job_completion_email(user_email, result)
    @result = result
    mail(to: user_email, subject: 'SchmidGrowthModel Job Completed')
  end
end

