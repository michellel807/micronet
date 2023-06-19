class HomeController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @selected_chart_types = [] # Initialize the selected_chart_types variable
    @charts_data = {}
    DirectoryInitializer.create_upload_directory()
    @data_file_paths = session[:data_file_paths] || []
    @mapping_file_paths = session[:mapping_file_paths]&.first || ""
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
  redirect_to '/home', notice: 'Files uploaded successfully.'
end

helper_method :convert_asc_to_tab_delimited
def convert_asc_to_tab_delimited(file_path)
  input_file_path = file_path
  output_file_path = Rails.root.join('public', 'uploads', 'userexpt', 'data',File.basename(file_path, '.*') + '.txt')

  # Call the Python script
  system("python lib/scripts/otherscripts/convertasc.py #{input_file_path} #{output_file_path}")

  output_file_path.to_s
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