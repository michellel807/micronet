class UploadController < ApplicationController
skip_before_action :verify_authenticity_token
require 'json'
require 'tmpdir'
require 'tempfile'

SavedUpload = Struct.new(:path, :original_filename)


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

  # Saved selections are indices into this session, never client-provided paths.
  saved_pairs = saved_upload_pairs(current_job)
  retained_pairs = params[:retained_pairs]
  uploads_changed = data_files_by_key.present? || mapping_files_by_key.present? ||
    meta_files.present? || interval_files.present? ||
    Array(params[:remove_data_pairs]).present? || Array(params[:remove_mapping_pairs]).present? ||
    params[:remove_meta_file] == "1" || params[:remove_interval_file] == "1" ||
    (retained_pairs.respond_to?(:values) ? retained_pairs.values.sort : []) != saved_pairs.map { |pair| pair[:id].to_s }.sort
  if retained_pairs.respond_to?(:each_pair)
    retained_pairs.each_pair do |key, saved_index|
      pair = saved_pairs.find { |entry| entry[:id].to_s == saved_index.to_s }
      next unless pair

      data_files_by_key[key] ||= saved_upload(current_job, pair[:data_path], pair[:data_name], "data") unless Array(params[:remove_data_pairs]).include?(key)
      mapping_files_by_key[key] ||= saved_upload(current_job, pair[:mapping_path], pair[:mapping_name], "mapping", pair[:plate_id]) unless Array(params[:remove_mapping_pairs]).include?(key)
    end
  end
  meta_files ||= saved_upload(current_job, session[:meta_file_path], session[:usr_meta_file_path], "meta") unless params[:remove_meta_file] == "1"
  interval_files ||= saved_upload(current_job, session[:interval_file_path], session[:usr_interval_file_path], "interval") unless params[:remove_interval_file] == "1"
  data_files_by_key.compact!
  mapping_files_by_key.compact!

  if data_files_by_key.blank?
    flash.alert = "Please upload at least one data file."
    redirect_to upload_path and return
  end

  @gp_time_step_size = normalize_gp_time_step_size(params[:gp_time_step_size])
  unless @gp_time_step_size
    restore_upload_state_from_session
    @gp_time_step_size = params[:gp_time_step_size].presence || Job::DEFAULT_TSS
    flash.now[:alert] = "Please enter a whole number of 1 or greater for the Gaussian Process time step size."
    return render :index
  end

  # Every submitted or retained data row needs its matching mapping file.
  if data_files_by_key.keys.sort != mapping_files_by_key.keys.sort
    flash.alert = "Each pair must include both a data file and a mapping file."
    redirect_to upload_path and return
  end

  unless uploads_changed
    restore_upload_state_from_session
    return render :index unless valid_gp_time_step_size_for_paths?(@data_file_paths, @gp_time_step_size)

    session[:gp_time_step_size] = @gp_time_step_size
    redirect_to selectanalyses_path and return
  end

  pair_keys_in_order = data_files_by_key.keys.sort_by(&:to_i)
  pair_entries = pair_keys_in_order.map do |pair_key|
    [data_files_by_key[pair_key], mapping_files_by_key[pair_key]]
  end
  meta_file = nil
  # Validate a separate copy so a failed edit cannot overwrite saved uploads.
  staging_root = Pathname.new(Dir.mktmpdir("micronet-upload-"))
  archive_uploads(staging_root, pair_entries, meta_files, interval_files)

  # Initialize the interval file if it exists
  if interval_files.present?
    interval_file = IntervalFile.new(interval_files, upload_root: staging_root)
    unless interval_file.valid?
      flash[:alert] = interval_file.error_message
      @interval_file_path = nil
      return render :index
    end
    @usr_interval_file_path = interval_files.original_filename.to_s
    @interval_file_path = interval_file.file_path.to_s
  end

  if meta_files.present?
    meta_file = MetaFile.new(meta_files, upload_root: staging_root)
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
        upload_root: staging_root,
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
      upload_root: staging_root,
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

  write_pair_metadata(current_job, pair_metadata_entries, root: staging_root)

  success = compare_pairs.all? do |data_file_path, mapping_file_path|
    Python.exec("lib/scripts/otherscripts/comparedataandmapping.py '#{data_file_path}' '#{mapping_file_path}'")
  end

  if @meta_file_path.present? && @data_file_paths.present?
    # Run the Python script to merge meta data with data files
    success &&= Python.exec("lib/scripts/otherscripts/mergemeta.py #{staging_root.join('data')} #{staging_root.join('mapping')} #{staging_root.join('pair_metadata.json')}")
    @mapping_file_paths = Dir.glob(staging_root.join('mapping', '*.txt'))
                         .reject { |path| File.basename(path) == 'meta.txt' }
                         .map(&:to_s)

  end

  if success
    unless valid_gp_time_step_size_for_paths?(@data_file_paths, @gp_time_step_size, flash_now: false)
      redirect_to upload_path and return
    end

    # Replace only upload inputs; leave generated result directories alone.
    %w[data mapping parameters originals].each do |directory|
      destination = current_job.upload_root.join(directory)
      FileUtils.rm_rf(destination)
      source = staging_root.join(directory)
      FileUtils.mv(source, destination) if source.exist?
    end
    current_job.ensure_upload_directories!
    FileUtils.cp(staging_root.join("pair_metadata.json"), current_job.pair_metadata_path)
    @data_file_paths.map! { |path| path.sub(staging_root.to_s, current_job.upload_root.to_s) }
    @mapping_file_paths.map! { |path| path.sub(staging_root.to_s, current_job.upload_root.to_s) }
    @meta_file_path = @meta_file_path&.sub(staging_root.to_s, current_job.upload_root.to_s)
    @interval_file_path = @interval_file_path&.sub(staging_root.to_s, current_job.upload_root.to_s)
    persist_upload_session!
    session[:gp_time_step_size] = @gp_time_step_size
    # Reset analysis selections so a new upload starts fresh
    %i[chart_types pool_replicates pool_options gp_pool_by_column
       gp_subset_choice gp_subset_column gp_conditions
       heatmap_value heatmap_x heatmap_y column_test column_pooled].each do |key|
      session.delete(key) if uploads_changed
    end
    flash.notice = "Files uploaded successfully! Proceeding to analyses selection..."
    # Redirect directly to next step (SelectAnalyses) on successful upload
    redirect_to '/selectanalyses'
  else
    flash.alert = "Files do not match. Please check your files and try again."
    redirect_to upload_path
  end
ensure
  FileUtils.remove_entry(staging_root) if staging_root && staging_root.exist?
  Array(@saved_upload_tempfiles).each(&:close!)

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

def saved_upload_pairs(job)
  metadata = job && job.pair_metadata_path.exist? ? JSON.parse(File.read(job.pair_metadata_path)).fetch("pairs", []) : []
  Array(session[:data_file_paths]).each_with_index.map do |path, index|
    entry = metadata.find { |pair| pair["pair_key"] == File.basename(path, ".txt") } || {}
    mapping_index = Array(session[:mapping_file_paths]).index { |mapping| File.basename(mapping) == File.basename(path) }
    mapping_index ||= index if metadata.empty? && Array(session[:mapping_file_paths]).length == Array(session[:data_file_paths]).length
    {
      id: index, data_path: path, data_name: Array(session[:usr_data_file_paths])[index],
      mapping_path: mapping_index && session[:mapping_file_paths][mapping_index],
      mapping_name: entry["original_mapping_filename"].presence || (metadata.empty? && mapping_index && Array(session[:usr_mapping_file_paths])[mapping_index]),
      plate_id: entry["parsed_plate_id"]
    }
  end
end

helper_method :saved_upload_pairs

def saved_upload(job, path, filename, kind, plate_id = nil)
  return unless path.present? && filename.present? && File.file?(path)

  basename = %w[data mapping].include?(kind) ? File.basename(path, ".txt") : kind
  original = job.upload_root.join("originals", kind, "#{basename}#{File.extname(filename)}")
  return SavedUpload.new(original.to_s, filename) if original.file?

  # Adapt normalized files if originals are unavailable during an edit.
  tempfile = Tempfile.new(["saved-upload", File.extname(filename)])
  (@saved_upload_tempfiles ||= []) << tempfile
  if kind == "mapping" && plate_id.present?
    table = CSV.read(path, headers: true, col_sep: "\t")
    table.each { |row| row["Plate_ID"] = plate_id } if table.headers.include?("Plate_ID")
    CSV.open(tempfile.path, "w", col_sep: File.extname(filename).downcase == ".csv" ? "," : "\t") do |csv|
      csv << table.headers
      table.each { |row| csv << row.fields }
    end
  elsif File.extname(filename).downcase == ".csv"
    CSV.open(tempfile.path, "w") { |csv| CSV.foreach(path, col_sep: "\t") { |row| csv << row } }
  else
    FileUtils.cp(path, tempfile.path)
  end
  SavedUpload.new(tempfile.path, filename)
end

def archive_uploads(root, pairs, meta, interval)
  entries = pairs.each_with_index.flat_map do |(data, mapping), index|
    [[data, "data", "file#{index + 1}"], [mapping, "mapping", "file#{index + 1}"]]
  end
  entries += [[meta, "meta", "meta"], [interval, "interval", "interval"]]
  entries.each do |file, kind, basename|
    next unless file

    directory = root.join("originals", kind)
    FileUtils.mkdir_p(directory)
    FileUtils.cp(file.path, directory.join("#{basename}#{File.extname(file.original_filename)}"))
  end
end

def write_pair_metadata(job, pair_entries, root: job.upload_root)
  metadata = {
    "job_id" => job.id,
    "generated_at" => Time.current.iso8601,
    "pairs" => pair_entries
  }
  File.write(root.join("pair_metadata.json"), JSON.pretty_generate(metadata))
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
