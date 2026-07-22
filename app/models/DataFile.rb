require 'csv'

class DataFile
  attr_reader :file_path, :error_message

  def initialize(file, mapping_plate_id, upload_root:, output_basename: nil)
    @file = file
    @upload_root = upload_root
    @output_basename = output_basename
    valid_extensions = ['.txt', '.asc', '.tsv', '.csv']
    if valid_extensions.include?(File.extname(file.original_filename).downcase)
      @file_path = save_file(file, mapping_plate_id)
    else
      @error_message = 'Invalid data file format. Please ensure that your data file is a .asc, .txt, .tsv, or .csv file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path)
  end
  
  private
  
  def save_file(file, mapping_plate_id)
    directory_path = @upload_root.join('data')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)
  
    original_filename = file.original_filename
    file_extension = File.extname(original_filename).downcase
    basename = @output_basename.presence || mapping_plate_id.presence || File.basename(original_filename, '.*')
    new_filename = "#{File.basename(basename.to_s, '.*')}.txt"
    txt_file = directory_path.join(new_filename)
  
    if file_extension == '.csv'
      File.open(txt_file, 'w') do |f|
        CSV.foreach(file.path, encoding: 'UTF-8') do |row|
          f.puts row.join("\t")
        end
      end
    else
      # Keep non-CSV inputs unchanged; AMiGA handles content validation/parsing.
      FileUtils.cp(file.path, txt_file)
    end

    txt_file.to_s
  end
end
