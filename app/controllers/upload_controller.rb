class UploadController < ApplicationController
skip_before_action :verify_authenticity_token

def delete_files
  # Clear session variables
  session[:data_file_paths] = nil
  session[:mapping_file_paths] = nil
  @data_file_paths = session[:data_file_paths]
  @mapping_file_paths = session[:mapping_file_paths]

  puts "Session[:data_file_paths] is #{session[:data_file_paths] }"
  puts "Session[:mapping_file_paths] is #{session[:mapping_file_paths] }"
  puts "@data_file_paths is #{@data_file_paths}"
  puts "@mapping_file_paths is #{@mapping_file_paths}"
  redirect_to '/upload', notice: 'No files currently uploaded.'

end

def index
  @job = Job.find(session[:current_user_id]) if session[:current_user_id]
  @selected_chart_types = [] # Initialize the selected_chart_types variable
  @charts_data = {}
  DirectoryInitializer.create_upload_directory()
  @data_file_paths = [] # Initialize @data_file_paths as an empty array
  @data_file_paths = session[:data_file_paths] if session[:data_file_paths].present?
  session[:data_file_paths] = @data_file_paths
  @mapping_file_paths = session[:mapping_file_paths] || [] # Assign an empty array if session value is nil
  session[:mapping_file_paths] ||= @mapping_file_paths # Set the session value if it's nil
  @data_file_names = @data_file_paths.map { |file_path| File.basename(file_path) }
  @mapping_file_names = @mapping_file_paths.map { |file_path| File.basename(file_path) }
end


def upload
  @data_file_paths = []
  @mapping_file_paths = []

  data_files = Array(params[:data_files])
  mapping_files = Array(params[:mapping_files])

  # Handle data files
  data_files.each do |file|
    data_file = DataFile.new(file)
    @data_file_paths << data_file.file_path.to_s # Add the file path to the instance variable

    unless data_file.valid?
      flash.now.alert = data_file.error_message
      @mapping_file_paths = session[:mapping_file_paths] || [] # Reset mapping file paths
      @data_file_paths = [] # Clear data file paths
      return render :index
    end
  end

  # Handle mapping files
  mapping_files.each do |file|
    mapping_file = MappingFile.new(file)
    @mapping_file_paths << mapping_file.file_path.to_s # Add the file path to the instance variable

    unless mapping_file.valid?
      flash.now.alert = mapping_file.error_message
      @mapping_file_paths = [] # Clear mapping file paths
      @data_file_paths = session[:data_file_paths] || [] # Reset data file paths
      return render :index
    end
  end

  session[:data_file_paths] = @data_file_paths
  session[:mapping_file_paths] = @mapping_file_paths

  @upload_completed = true # Set flag for "Next" button to appear, etc

  redirect_to '/upload', notice: 'Files uploaded successfully.'
end

  
  

helper_method :convert_asc_to_tab_delimited
def convert_asc_to_tab_delimited(file_path)
  input_file_path = file_path
  output_file_path = Rails.root.join('private', 'uploads', 'userexpt', 'data', File.basename(file_path, '.*') + '.txt')

  # Call the Python script and check for errors
  success = system("python lib/scripts/otherscripts/convertasc.py #{input_file_path} #{output_file_path}")

  return nil unless success && File.exist?(output_file_path)

  output_file_path.to_s
end



require 'fileutils'

#def delete_files
#  upload_directory = Rails.root.join('private', 'uploads', 'userexpt')
#  FileUtils.rm_rf(upload_directory)
#end

#at_exit do
#  UploadController.new.delete_files
# end
end
