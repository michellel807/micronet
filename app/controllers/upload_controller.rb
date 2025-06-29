class UploadController < ApplicationController
skip_before_action :verify_authenticity_token


def delete_files
  # Clear data
  FileUtils.rm_rf(Rails.root.join('private', 'uploads', 'userexpt'))
  puts "files deleted"
  # Clear session variables
  session[:data_file_paths] = nil
  session[:mapping_file_paths] = nil
  session[:meta_file_path] = nil
  @data_file_paths = session[:data_file_paths]
  @mapping_file_paths = session[:mapping_file_paths]
  @meta_file_path = session[:meta_file_path]

  puts "Session[:data_file_paths] is #{session[:data_file_paths] }"
  puts "Session[:mapping_file_paths] is #{session[:mapping_file_paths] }"
  puts "Session[:meta_file_path] is #{session[:meta_file_path] }"
  puts "@data_file_paths is #{@data_file_paths}"
  puts "@mapping_file_paths is #{@mapping_file_paths}"
  puts "@meta_file_path is #{@meta_file_path}"
  redirect_to '/upload', notice: 'No files currently uploaded.'

end

def index
  @job = Job.find(session[:current_user_id]) if session[:current_user_id]
  @selected_chart_types = [] # Initialize the selected_chart_types variable
  @charts_data = {}
  DirectoryInitializer.create_upload_directory()

  @data_file_paths = session[:data_file_paths] || []     # Assign an empty array if session value is nil
  session[:data_file_paths] = @data_file_paths           # Set the session value if it's nil
  @mapping_file_paths = session[:mapping_file_paths] || [] 
  session[:mapping_file_paths] ||= @mapping_file_paths 
  @meta_file_path = session[:meta_file_path] || nil
  session[:meta_file_path] ||= @meta_file_path 
  @usr_data_file_paths = session[:usr_data_file_paths] || []
  session[:usr_data_file_paths] ||= @usr_data_file_paths
  @usr_mapping_file_paths = session[:usr_mapping_file_paths] || []
  session[:usr_mapping_file_paths] ||= @usr_mapping_file_paths
  @usr_meta_file_path = session[:usr_meta_file_path] || nil
  session[:usr_meta_file_path] ||= @usr_meta_file_path

  @usr_data_file_names = @usr_data_file_paths.map { |file_path| File.basename(file_path) }
  @usr_mapping_file_names = @usr_mapping_file_paths.map { |file_path| File.basename(file_path) }
  @usr_meta_file_name = File.basename(@usr_meta_file_path) if @usr_meta_file_path.present?
end


def upload
  @data_file_paths = []
  @usr_data_file_paths = []
  @mapping_file_paths = []
  @usr_mapping_file_paths = []
  @meta_file_path = nil
  @usr_meta_file_path = nil

  # Get uploaded files
  data_files = Array(params[:data_files])
  mapping_files = Array(params[:mapping_files])
  meta_files = params[:meta_files]

  if meta_files.present?
    meta_file = MetaFile.new(meta_files)
    unless meta_file.valid?
      flash[:alert] = meta_file.error_message
      @meta_file_path = nil
      return render :index
    end

    @usr_meta_file_path = meta_files.original_filename.to_s
    @meta_file_path = meta_file.file_path.to_s
  end

  # Get the order arrays from the hidden input fields
  ordered_data_names = JSON.parse(params[:ordered_data_files]) rescue []
  ordered_mapping_names = JSON.parse(params[:ordered_mapping_files]) rescue []

  # Reorder the uploaded files to match the submitted order
  ordered_data_files = ordered_data_names.map do |name|
    data_files.find { |file| file.original_filename == name }
  end.compact

  ordered_mapping_files = ordered_mapping_names.map do |name|
    mapping_files.find { |file| file.original_filename == name }
  end.compact

  # Use these for processing
  data_files = ordered_data_files
  mapping_files = ordered_mapping_files

  if data_files.size != mapping_files.size
    flash.alert = "The number of data files and mapping files does not match."
    redirect_to upload_path and return
  end

  data_files.zip(mapping_files).each do |data_file_input, mapping_file_input|
    mapping_file = MappingFile.new(mapping_file_input)
    data_file = DataFile.new(data_file_input, mapping_file.plate_id)

    @usr_data_file_paths << data_file_input.original_filename.to_s
    @usr_mapping_file_paths << mapping_file_input.original_filename.to_s
    @data_file_paths << data_file.file_path.to_s
    @mapping_file_paths << mapping_file.file_path.to_s

    unless data_file.valid?
      flash.alert = data_file.error_message
      @mapping_file_paths = session[:mapping_file_paths] || []
      @data_file_paths = [] # Clear invalid data file paths
      return render :index
    end

    unless mapping_file.valid?
      flash.alert = mapping_file.error_message
      @mapping_file_paths = [] # Clear invalid mapping file paths
      @data_file_paths = session[:data_file_paths] || []
      return render :index
    end
  end

  # Validate the data and mapping files and the meta file
  if @data_file_paths.present? && @mapping_file_paths.present?

    success = true

    if @meta_file_path.present?
      success &&= meta_file.plate_id_values.sort == @data_file_paths.map { |file_path| File.basename(file_path, '.*') }.sort
    end

    @data_file_paths.zip(@mapping_file_paths).each do |data_file_path, mapping_file_path|
      success &&= Python.exec("lib/scripts/otherscripts/comparedataandmapping.py '#{data_file_path}' '#{mapping_file_path}'")
    end

    if success
      # If the Python script ran successfully, set the session variables
      session[:data_file_paths] = @data_file_paths
      session[:mapping_file_paths] = @mapping_file_paths
      session[:usr_data_file_paths] = @usr_data_file_paths
      session[:usr_mapping_file_paths] = @usr_mapping_file_paths
      session[:meta_file_path] = @meta_file_path
      session[:usr_meta_file_path] = @usr_meta_file_path
      flash.notice = "Files uploaded successfully." # Use flash instead of flash.now
    else
      # If the Python script failed, clear the session variables
      session[:data_file_paths] = nil
      session[:mapping_file_paths] = nil
      session[:usr_data_file_paths] = nil
      session[:usr_mapping_file_paths] = nil
      session[:meta_file_path] = nil
      session[:usr_meta_file_path] = nil
      flash.alert = "Files do not match. Please check your files and try again." # Use flash instead of flash.now
      delete_files # Clear the uploaded files
      return
    end
  end

  redirect_to '/upload'
end


def create
  # Save uploaded files as needed...
  # Example: store original uploaded files (Rails' file upload logic depends on storage system)

  # Store the drag-and-drop order
  @usr_data_file_names = JSON.parse(params[:ordered_data_files] || "[]")
  @usr_mapping_file_names = JSON.parse(params[:ordered_mapping_files] || "[]")

  # Do something with the files and their order...
  flash.now[:notice] = "Files uploaded and order recorded."
  render :index
end



helper_method :convert_asc_to_tab_delimited
def convert_asc_to_tab_delimited(file_path)
  input_file_path = file_path
  output_file_path = Rails.root.join('private', 'uploads', 'userexpt', 'data', File.basename(file_path, '.*') + '.txt')

  # Call the Python script and check for errors
  success = Python.exec("lib/scripts/otherscripts/convertasc.py #{input_file_path} #{output_file_path}")

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
