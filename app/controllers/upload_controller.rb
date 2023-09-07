class UploadController < ApplicationController
skip_before_action :verify_authenticity_token


def delete_files
  # Clear data
  FileUtils.rm_rf(Rails.root.join('private', 'uploads', 'userexpt'))
  puts "files deleted"
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
      flash.alert = data_file.error_message # Use flash instead of flash.now
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
      flash.alert = mapping_file.error_message # Use flash instead of flash.now
      @mapping_file_paths = [] # Clear mapping file paths
      @data_file_paths = session[:data_file_paths] || [] # Reset data file paths
      return render :index
    end
  end

  # Call the Python script to compare the data and mapping files
  if @data_file_paths.present? && @mapping_file_paths.present?
    data_file_path = @data_file_paths[0] # Assuming you want to compare the first data file
    mapping_file_path = @mapping_file_paths[0] # Assuming you want to compare the first mapping file
    command = "source activate #{Rails.configuration.python_conda_location} && python lib/scripts/otherscripts/comparedataandmapping.py '#{data_file_path}' '#{mapping_file_path}'"
    logger.debug("command: [#{command}]")
    success = system("bash","-c", command)

    if success
      # If the Python script ran successfully, set the session variables
      session[:data_file_paths] = @data_file_paths
      session[:mapping_file_paths] = @mapping_file_paths
      flash.notice = "Files uploaded successfully." # Use flash instead of flash.now
    else
      # If the Python script failed, clear the session variables
      session[:data_file_paths] = nil
      session[:mapping_file_paths] = nil
      flash.alert = "Files do not match. Please check your files and try again." # Use flash instead of flash.now
    end
  end

  redirect_to '/upload'
end


helper_method :convert_asc_to_tab_delimited
def convert_asc_to_tab_delimited(file_path)
  input_file_path = file_path
  output_file_path = Rails.root.join('private', 'uploads', 'userexpt', 'data', File.basename(file_path, '.*') + '.txt')

  # Call the Python script and check for errors
  success = system("bash", "-c", "source activate #{Rails.configuration.python_conda_location} && python lib/scripts/otherscripts/convertasc.py #{input_file_path} #{output_file_path}")

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
