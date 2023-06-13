 def generate_charts
    @file_path = session[:file_path]
    scatter_path = Rails.root.join('lib', 'scripts', 'scatterplot.py')
    @selected_chart_types = params[:chart_types] || []

    # Generate the desired charts based on the selected chart types
    if @selected_chart_types.include?('raw_data')
    system("source activate lib/envs/amigacondaenv/ && lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py summarize -i public/uploads/userexpt/")
    @raw_data_pdf_paths = Dir.glob(Rails.root.join('public', 'uploads', 
'userexpt', 'figures', '*.pdf'))

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

    if @selected_chart_types.include?('scatter_plot')
      system("python #{scatter_path} '#{@file_path}'")
      @scatter_plot = '/uploads/scatterplot.png'
    end

    if @selected_chart_types.include?('fit_stats')
    #system("source activate lib/envs/amigacondaenv/ && 
lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py fit 
-i public/uploads/userexpt")
    @fit_stats_paths = Dir.glob(Rails.root.join('public', 'uploads', 
'userexpt', 'summary', '*_summary.txt'))
    end

    respond_to do |format|
      format.html do
        if @selected_chart_types.any?
          render partial: 'plots', locals: { fit_stats_paths: 
@fit_stats_paths, raw_data_pdf_paths: 
@raw_data_pdf_paths, 
scatter_plot: @scatter_plot }
        else
          render plain: 'No chart types selected.'
        end
      end
    end
  end
  def serve_image
    filename = params[:filename]
    file_path = Rails.root.join('public', 'uploads', 'userexpt', 'figures', 
filename)
    
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
