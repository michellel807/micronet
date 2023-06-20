class UploadController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @selected_chart_types = [] # Initialize the selected_chart_types variable
    @charts_data = {}
    DirectoryInitializer.create_upload_directory()
    @data_file_paths = [] # Initialize @data_file_paths as an empty array
    @data_file_paths = session[:data_file_paths] if session[:data_file_paths].present?
    @mapping_file_paths = session[:mapping_file_paths]&.first || ""
  end

def upload
  @data_file_paths = []
  data_files = Array(params[:data_files])
  data_files.each do |file|
    data_file = DataFile.new(file)
    puts "Data file upload done"
    @data_file_paths << data_file.file_path.to_s # Add the file path to the instance variable
  end

  @mapping_file_paths = []
  mapping_files = Array(params[:mapping_files])
  mapping_files.each do |file|
    mapping_file = MappingFile.new(file)
    puts "Mapping file upload done"
    @mapping_file_paths << mapping_file.file_path.to_s # Add the file path to the instance variable
  end
  
  @upload_completed = true #set flag for "Next" button to appear, etc
  puts "Upload completed status: #{@upload_completed}"

  redirect_to '/upload', notice: 'Files uploaded successfully.'
end

helper_method :convert_asc_to_tab_delimited
def convert_asc_to_tab_delimited(file_path)
  input_file_path = file_path
  output_file_path = Rails.root.join('public', 'uploads', 'userexpt', 'data', File.basename(file_path, '.*') + '.txt')

  # Call the Python script and check for errors
  success = system("python lib/scripts/otherscripts/convertasc.py #{input_file_path} #{output_file_path}")

  return nil unless success && File.exist?(output_file_path)

  output_file_path.to_s
end



require 'fileutils'

def delete_files
  upload_directory = Rails.root.join('public', 'uploads', 'userexpt')
  FileUtils.rm_rf(upload_directory)
end

at_exit do
  UploadController.new.delete_files
 end
end
