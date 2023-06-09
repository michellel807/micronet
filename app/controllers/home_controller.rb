class HomeController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @selected_chart_types = [] # Initialize the selected_chart_types variable
    @charts_data = {}
    DirectoryInitializer.create_upload_directory()
  end

def upload
  data_files = Array(params[:data_files])
  data_files.each do |file|
    data_file = DataFile.new(file)
      puts "Data file upload done"
      session[:data_file_paths] ||= [] # Initialize session[:data_file_paths] as an empty array if it doesn't exist
      session[:data_file_paths] << data_file.file_path.to_s # Add the file path to the session array
  end

  mapping_files = Array(params[:mapping_files])
  mapping_files.each do |file|
    mapping_file = MappingFile.new(file)
      puts "Mapping file upload done"
      session[:mapping_file_paths] ||= [] # Initialize session[:mapping_file_paths] as an empty array if it doesn't exist
      session[:mapping_file_paths] << mapping_file.file_path.to_s # Add the file path to the session array
  end

  redirect_to root_path, notice: 'Files uploaded successfully.'
end

  def generate_charts
    @selected_chart_types = params[:chart_types] || []

    if @selected_chart_types.include?('raw_data')
      raw_data_results = RawDataGenerator.generate_raw_data()
      @raw_data_pdf_paths = raw_data_results[:raw_data_pdf_paths]
      @raw_data_png_paths = raw_data_results[:raw_data_png_paths]
    end

    if @selected_chart_types.include?('fit_stats')
      @fit_stats_paths = FitStatisticsGenerator.generate_fit_stats()
    end

    respond_to do |format|
      format.html do
        if @selected_chart_types.any?
          render partial: 'plots', locals: { fit_stats_paths: @fit_stats_paths, raw_data_pdf_paths: @raw_data_pdf_paths }
        else
          render plain: 'No chart types selected.'
        end
      end
    end
  end

  def serve_image
    filename = params[:filename]
    file_path = Rails.root.join('public', 'uploads', 'userexpt', 'figures', filename)
    
    if File.exist?(file_path) && File.file?(file_path)
      send_file file_path, disposition: 'inline'
    else
      head :not_found
    end
  end

require 'fileutils'

def delete_files
  upload_directory = Rails.root.join('public', 'uploads', 'userexpt')
  FileUtils.rm_rf(upload_directory)
end

at_exit do
  HomeController.new.delete_files
 end
end



