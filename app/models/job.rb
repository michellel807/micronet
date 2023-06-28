class Job < ApplicationRecord
  belongs_to :user

  def analyze(chart_types)
    self.status = "Analyzing..."
    @selected_chart_types = chart_types || []
    if @selected_chart_types.include?('raw_data')
      raw_data_results = RawDataGenerator.generate_raw_data()
      @raw_data_pdf_paths = raw_data_results[:raw_data_pdf_paths]
      @raw_data_png_paths = raw_data_results[:raw_data_png_paths]
    end

    if @selected_chart_types.include?('fit_stats')
      @fit_stats_paths = FitStatisticsGenerator.generate_fit_stats()
    end

    save # Save the instance of Job

    # Prepare the file names to be sent in the email
    file_names = []
    file_names += @raw_data_pdf_paths if @raw_data_pdf_paths.present?
    file_names += @raw_data_png_paths if @raw_data_png_paths.present?
    file_names += @fit_stats_paths if @fit_stats_paths.present?

    # Send email to the user with the file names and the job object
    UserMailer.welcome_email(file_names, self).deliver_now
  end

  def serve_image
    filename = params[:filename]
    file_path = Rails.root.join('private', 'uploads', 'userexpt', 'figures', filename)
    
    if File.exist?(file_path) && File.file?(file_path)
      send_file file_path, disposition: 'inline'
    else
      head :not_found
    end
  end

  def sendconfirm
    logger.info("Sending confirmation for job id: #{id}")
    UserMailer.with(job: self, user: User.find(self.user_id)).confirm_email.deliver_now
  end


end
