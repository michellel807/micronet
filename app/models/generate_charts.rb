def generate_charts
  @file_path = session[:file_path]
  @selected_chart_types = params[:chart_types] || []
  # Remove the figures and summary directory before running analyses (otherwise the email will just send whatever figures are currently in the dir)
  FileUtils.rm_rf(Rails.root.join('private', 'uploads', 'userexpt', 'figures'))
  FileUtils.rm_rf(Rails.root.join('private', 'uploads', 'userexpt', 'summary'))

  # Generate the desired charts based on the selected chart types
  if @selected_chart_types.include?('raw_data')
  system("source activate #{Rails.configuration.python_conda_location} && python lib/scripts/amigagitsimplified/amiga.py summarize -i private/uploads/userexpt/")
  @raw_data_pdf_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'figures', '*.pdf'))

    # Convert PDFs to PNGs
    @raw_data_png_paths = []
    @raw_data_pdf_paths.each do |pdf_path|
      png_path = pdf_path.sub('.pdf', '.png')
      require "mini_magick"
      MiniMagick::Tool::Convert.new do |convert|
        convert << pdf_path
        convert << png_path
      end
      @raw_data_png_paths << png_path
     end
  end


  if @selected_chart_types.include?('fit_stats')
  selected_options_string = @selected_options.join(",") #convert to string so python can use it
    if selected_options_string
      system("source activate #{Rails.configuration.python_conda_location} && python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt --pool-by #{selected_options_string}")
    else
      system("source activate #{Rails.configuration.python_conda_location} && python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt")
    end
  @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', '*_summary.txt'))
  end

  respond_to do |format|
    format.html do
      if @selected_chart_types.any?
        render partial: 'plots', locals: { fit_stats_paths: @fit_stats_paths, raw_data_pdf_paths: @raw_data_pdf_paths }
      else
        render plain: 'No analyses selected.'
      end
    end
  end
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
  UserMailer.with(job: self, user:
User.find(self.user_id)).confirm_email.deliver
end
end
