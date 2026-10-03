class UploadController < ApplicationController
skip_before_action :verify_authenticity_token
require 'json'


def delete_files
  # Clear data
  @job = Job.find_by(id: session[:current_user_id])
  @job&.clear_uploads!
  puts "files deleted"
  # Clear session variables
  session[:data_file_paths] = nil
  session[:mapping_file_paths] = nil
  session[:meta_file_path] = nil
  session[:interval_file_path] = nil
  session[:usr_data_file_paths] = nil
  session[:usr_mapping_file_paths] = nil
  session[:usr_meta_file_path] = nil
  session[:usr_interval_file_path] = nil
  session[:gp_time_step_size] = nil
  @data_file_paths = session[:data_file_paths]
  @mapping_file_paths = session[:mapping_file_paths]
  @meta_file_path = session[:meta_file_path]
  @interval_file_path = session[:interval_file_path]
  @gp_time_step_size = session[:gp_time_step_size] || Job::DEFAULT_TSS

  puts "Session[:data_file_paths] is #{session[:data_file_paths] }"
  puts "Session[:mapping_file_paths] is #{session[:mapping_file_paths] }"
  puts "Session[:meta_file_path] is #{session[:meta_file_path] }"
  puts "Session[:interval_file_path] is #{session[:interval_file_path] }"
  puts "@data_file_paths is #{@data_file_paths}"
  puts "@mapping_file_paths is #{@mapping_file_paths}"
  puts "@meta_file_path is #{@meta_file_path}"
  puts "@interval_file_path is #{@interval_file_path}"
  redirect_to '/upload', notice: 'No files currently uploaded.'

end

def index
  @job = Job.find(session[:current_user_id]) if session[:current_user_id]
  @selected_chart_types = [] # Initialize the selected_chart_types variable
  @charts_data = {}
  @job&.ensure_upload_directories!

  @data_file_paths = session[:data_file_paths] || []     # Assign an empty array if session value is nil
  session[:data_file_paths] = @data_file_paths           # Set the session value if it's nil
  @mapping_file_paths = session[:mapping_file_paths] || [] 
  session[:mapping_file_paths] ||= @mapping_file_paths 
  @meta_file_path = session[:meta_file_path] || nil
  session[:meta_file_path] ||= @meta_file_path 
  @interval_file_path = session[:interval_file_path] || nil
  session[:interval_file_path] ||= @interval_file_path 
  @usr_data_file_paths = session[:usr_data_file_paths] || []
  session[:usr_data_file_paths] ||= @usr_data_file_paths
  @usr_mapping_file_paths = session[:usr_mapping_file_paths] || []
  session[:usr_mapping_file_paths] ||= @usr_mapping_file_paths
  @usr_meta_file_path = session[:usr_meta_file_path] || nil
  session[:usr_meta_file_path] ||= @usr_meta_file_path
  @usr_interval_file_path = session[:usr_interval_file_path] || nil
  session[:usr_interval_file_path] ||= @usr_interval_file_path
  @gp_time_step_size = session[:gp_time_step_size] || Job::DEFAULT_TSS

  @usr_data_file_names = @usr_data_file_paths.map { |file_path| File.basename(file_path) }
  @usr_mapping_file_names = @usr_mapping_file_paths.map { |file_path| File.basename(file_path) }
  @usr_meta_file_name = File.basename(@usr_meta_file_path) if @usr_meta_file_path.present?
  @usr_interval_file_name = File.basename(@usr_interval_file_path) if @usr_interval_file_path.present?
end


def upload
  @data_file_paths = []
  @usr_data_file_paths = []
  @mapping_file_paths = []
  @usr_mapping_file_paths = []
  @meta_file_path = nil
  @usr_meta_file_path = nil
  @interval_file_path = nil
  @usr_interval_file_path = nil
  @gp_time_step_size = Job::DEFAULT_TSS
  current_job = Job.find(session[:current_user_id])
  current_job.ensure_upload_directories!

  current_job = Job.find(session[:current_user_id])
  current_job.ensure_upload_directories!

  # Get uploaded files from explicit pair rows.
  data_pairs_param = params[:data_pair_files]
  mapping_pairs_param = params[:mapping_pair_files]
  data_files_by_key =
    if data_pairs_param.respond_to?(:to_unsafe_h)
      data_pairs_param.to_unsafe_h
    elsif data_pairs_param.present?
      data_pairs_param.to_h
    else
      {}
    end
  mapping_files_by_key =
    if mapping_pairs_param.respond_to?(:to_unsafe_h)
      mapping_pairs_param.to_unsafe_h
    elsif mapping_pairs_param.present?
      mapping_pairs_param.to_h
    else
      {}
    end
  data_files_by_key = data_files_by_key.compact
  mapping_files_by_key = mapping_files_by_key.compact
  meta_files = params[:meta_files]
  interval_files = params[:interval_files]
  @gp_time_step_size = params[:gp_time_step_size].presence || Job::DEFAULT_TSS

  if data_files_by_key.blank?
    if mapping_files_by_key.present?
      flash.alert = "Each pair row with a mapping file must also include a data file."
      redirect_to upload_path and return
    end

    if session[:data_file_paths].present?
      normalized_tss = normalize_gp_time_step_size(params[:gp_time_step_size])
      unless normalized_tss
        restore_upload_state_from_session
        @gp_time_step_size = params[:gp_time_step_size].presence || Job::DEFAULT_TSS
        flash.now[:alert] = "Please enter a whole number of 1 or greater for the Gaussian Process time step size."
        return render :index
      end

      @gp_time_step_size = normalized_tss
      restore_upload_state_from_session

      unless valid_gp_time_step_size_for_paths?(session[:data_file_paths], @gp_time_step_size)
        return render :index
      end

      session[:gp_time_step_size] = @gp_time_step_size
      flash.notice = "Time step size updated. Proceeding to analyses selection..."
      redirect_to '/selectanalyses'
      return
    end

    flash.alert = "Please upload at least one data file."
    redirect_to upload_path and return
  end

  # Any mapping upload without a matching data row is invalid.
  extra_mapping_keys = mapping_files_by_key.keys - data_files_by_key.keys
  if extra_mapping_keys.present?
    flash.alert = "Each pair row with a mapping file must also include a data file."
    redirect_to upload_path and return
  end

  pair_keys_in_order = data_files_by_key.keys.sort_by(&:to_i)
  pair_entries = pair_keys_in_order.map do |pair_key|
    [data_files_by_key[pair_key], mapping_files_by_key[pair_key]]
  end
  meta_file = nil

  # Initialize the interval file if it exists
  if interval_files.present?
    interval_file = IntervalFile.new(interval_files, upload_root: current_job.upload_root)
    unless interval_file.valid?
      flash[:alert] = interval_file.error_message
      @interval_file_path = nil
      return render :index
    end
    @usr_interval_file_path = interval_files.original_filename.to_s
    @interval_file_path = interval_file.file_path.to_s
  end

  if meta_files.present?
    meta_file = MetaFile.new(meta_files, upload_root: current_job.upload_root)
    unless meta_file.valid?
      flash[:alert] = meta_file.error_message
      @meta_file_path = nil
      return render :index
    end
    @usr_meta_file_path = meta_files.original_filename.to_s
    @meta_file_path = meta_file.file_path.to_s
  end

  # Keep compare-validation aligned only to pairs that include both files.
  compare_pairs = []
  pair_metadata_entries = []

  pair_entries.each_with_index do |(data_file_input, mapping_file_input), pair_index|
    pair_basename = "file#{pair_index + 1}"
    mapping_file = nil

    if mapping_file_input.present?
      mapping_file = MappingFile.new(
        mapping_file_input,
        upload_root: current_job.upload_root,
        output_basename: pair_basename
      )

      unless mapping_file.valid?
        flash.alert = mapping_file.error_message
        @mapping_file_paths = [] # Clear invalid mapping file paths
        @data_file_paths = session[:data_file_paths] || []
        return render :index
      end

      @usr_mapping_file_paths << mapping_file_input.original_filename.to_s
      @mapping_file_paths << mapping_file.file_path.to_s
    end

    data_file = DataFile.new(
      data_file_input,
      mapping_file&.plate_id,
      upload_root: current_job.upload_root,
      output_basename: pair_basename
    )

    unless data_file.valid?
      flash.alert = data_file.error_message
      @mapping_file_paths = session[:mapping_file_paths] || []
      @data_file_paths = []
      return render :index
    end

    @usr_data_file_paths << data_file_input.original_filename.to_s
    @data_file_paths << data_file.file_path.to_s

    pair_metadata_entries << {
      "pair_key" => pair_basename,
      "pair_index" => pair_index + 1,
      "original_data_filename" => data_file_input.original_filename.to_s,
      "original_mapping_filename" => mapping_file_input&.original_filename.to_s,
      "parsed_plate_id" => mapping_file&.plate_id.to_s.presence
    }

    if mapping_file.present?
      compare_pairs << [data_file.file_path.to_s, mapping_file.file_path.to_s]
    end
  end

  write_pair_metadata(current_job, pair_metadata_entries)

  if meta_file.present? && compare_pairs.blank?
    if meta_file.plate_id_values.length != pair_entries.length
      flash.alert = "The number of data files does not match the number of plate IDs in the meta file."
      redirect_to upload_path and return
    end
  end

  # Validate the data and mapping files and the meta file
  success = false  # Start pessimistic by default

  # Case 1: data + mapping files
  if compare_pairs.present?
    success = true
    compare_pairs.each do |data_file_path, mapping_file_path|
      success &&= Python.exec("lib/scripts/otherscripts/comparedataandmapping.py '#{data_file_path}' '#{mapping_file_path}'")
    end

  # Case 2: data + meta file only (no mapping)
  elsif @data_file_paths.present? && @meta_file_path.present? && @mapping_file_paths.blank?
    success = true

  # Case 3: data files only (no mapping, no meta)
  elsif @data_file_paths.present? && @mapping_file_paths.blank? && @meta_file_path.nil?
    success = true

  else
    success = false
  end

  if @meta_file_path.present? && @data_file_paths.present?
    # Run the Python script to merge meta data with data files
    Python.exec("lib/scripts/otherscripts/mergemeta.py #{current_job.data_dir} #{current_job.mapping_dir} #{current_job.pair_metadata_path}")
    @mapping_file_paths = Dir.glob(current_job.mapping_dir.join('*.txt'))
                         .reject { |path| File.basename(path) == 'meta.txt' }
                         .map(&:to_s)

  end

  if success
    persist_upload_session!
    @gp_time_step_size = normalize_gp_time_step_size(params[:gp_time_step_size])

    unless @gp_time_step_size
      session[:gp_time_step_size] = Job::DEFAULT_TSS
      flash[:alert] = "Please enter a whole number of 1 or greater for the Gaussian Process time step size."
      redirect_to upload_path
      return
    end

    unless valid_gp_time_step_size_for_paths?(@data_file_paths, @gp_time_step_size, flash_now: false)
      session[:gp_time_step_size] = Job::DEFAULT_TSS
      redirect_to upload_path
      return
    end

    session[:gp_time_step_size] = @gp_time_step_size
    # Reset analysis selections so a new upload starts fresh
    %i[chart_types pool_replicates pool_options gp_pool_by_column
       gp_subset_choice gp_subset_column gp_conditions
       heatmap_value heatmap_x heatmap_y column_test column_pooled].each do |key|
      session.delete(key)
    end
    flash.notice = "Files uploaded successfully! Proceeding to analyses selection..."
    # Redirect directly to next step (SelectAnalyses) on successful upload
    redirect_to '/selectanalyses'
  else
    # If the Python script failed, clear the session variables
    session[:data_file_paths] = nil
    session[:mapping_file_paths] = nil
    session[:usr_data_file_paths] = nil
    session[:usr_mapping_file_paths] = nil
    session[:meta_file_path] = nil
    session[:usr_meta_file_path] = nil
    session[:interval_file_path] = nil
    session[:usr_interval_file_path] = nil
    session[:gp_time_step_size] = nil
    flash.alert = "Files do not match. Please check your files and try again." # Use flash instead of flash.now
    delete_files # Clear the uploaded files
    return
  end
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
  current_job = Job.find(session[:current_user_id])
  input_file_path = file_path
  output_file_path = current_job.data_dir.join(File.basename(file_path, '.*') + '.txt')

  # Call the Python script and check for errors
  success = Python.exec("lib/scripts/otherscripts/convertasc.py #{input_file_path} #{output_file_path}")

  return nil unless success && File.exist?(output_file_path)

  output_file_path.to_s
end


require 'fileutils'

private

def write_pair_metadata(job, pair_entries)
  metadata = {
    "job_id" => job.id,
    "generated_at" => Time.current.iso8601,
    "pairs" => pair_entries
  }
  File.write(job.pair_metadata_path, JSON.pretty_generate(metadata))
end

def normalize_gp_time_step_size(value)
  raw_value = value.to_s.strip
  return Job::DEFAULT_TSS if raw_value.blank?
  return nil unless raw_value.match?(/\A[1-9]\d*\z/)

  raw_value.to_i
end

def valid_gp_time_step_size_for_paths?(data_file_paths, selected_tss, flash_now: true)
  counts = Array(data_file_paths).map do |path|
    Job.time_point_count_for_data_file(path)
  end.compact

  valid_gp_time_step_size_for_counts?(counts, selected_tss, flash_now: flash_now)
end

def valid_gp_time_step_size_for_counts?(counts, selected_tss, flash_now: true)
  return true if counts.blank?

  minimum_time_points = counts.min

  if minimum_time_points < Job::MIN_GP_TIME_POINTS
    set_flash_alert(
      "Your data has #{minimum_time_points} time points. MicroNet needs at least " \
      "#{Job::MIN_GP_TIME_POINTS} time points for Gaussian Process fitting.",
      flash_now
    )
    return false
  end

  max_safe_tss = Job.max_safe_tss_for_time_points(minimum_time_points)

  if selected_tss > max_safe_tss
    set_flash_alert(
      "The selected Gaussian Process time step size is too large for this dataset. " \
      "Your smallest data file has #{minimum_time_points} time points, so please choose " \
      "#{max_safe_tss} or lower to keep at least #{Job::MIN_GP_TIME_POINTS} time points for fitting.",
      flash_now
    )
    return false
  end

  true
end

def set_flash_alert(message, flash_now)
  if flash_now
    flash.now[:alert] = message
  else
    flash[:alert] = message
  end
end

def persist_upload_session!
  session[:data_file_paths] = @data_file_paths
  session[:mapping_file_paths] = @mapping_file_paths
  session[:usr_data_file_paths] = @usr_data_file_paths
  session[:usr_mapping_file_paths] = @usr_mapping_file_paths
  session[:meta_file_path] = @meta_file_path
  session[:usr_meta_file_path] = @usr_meta_file_path
  session[:interval_file_path] = @interval_file_path
  session[:usr_interval_file_path] = @usr_interval_file_path
end

def restore_upload_state_from_session
  @data_file_paths = session[:data_file_paths] || []
  @mapping_file_paths = session[:mapping_file_paths] || []
  @usr_data_file_paths = session[:usr_data_file_paths] || []
  @usr_mapping_file_paths = session[:usr_mapping_file_paths] || []
  @meta_file_path = session[:meta_file_path]
  @usr_meta_file_path = session[:usr_meta_file_path]
  @interval_file_path = session[:interval_file_path]
  @usr_interval_file_path = session[:usr_interval_file_path]
  @gp_time_step_size ||= session[:gp_time_step_size] || Job::DEFAULT_TSS

  @usr_data_file_names = @usr_data_file_paths.map { |file_path| File.basename(file_path) }
  @usr_mapping_file_names = @usr_mapping_file_paths.map { |file_path| File.basename(file_path) }
  @usr_meta_file_name = File.basename(@usr_meta_file_path) if @usr_meta_file_path.present?
  @usr_interval_file_name = File.basename(@usr_interval_file_path) if @usr_interval_file_path.present?
end

#at_exit do
#  UploadController.new.delete_files
# end
end
