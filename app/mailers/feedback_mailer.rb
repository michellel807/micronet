# app/mailers/feedback_mailer.rb
class FeedbackMailer < ApplicationMailer
    default to: 'phenom.duke.app@gmail.com', subject: 'New Feedback Received'
  
    def new_feedback(feedback)
      @feedback = feedback
      mail
    end
  end
  