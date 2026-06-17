require 'csv'

class MappingFile
  attr_reader :file_path, :plate_id, :error_message

  def initialize(file, upload_root:)
    @file = file
    @upload_root = upload_root
    valid_extensions = ['.txt', '.asc', '.tsv', '.csv']
    if valid_extensions.include?(File.extname(file.original_filename).downcase)
      print("Valid mapping file detected: #{file.original_filename}\n")
      @file_path = save_file(file)
    else
      @error_message = 'Invalid mapping file format. Please ensure that your mapping file is a .asc, .txt, .tsv, or .csv file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path) 
  end
  
  private

  def save_file(file)
    directory_path = @upload_root.join('mapping')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)
  
    original_filename = file.original_filename
    file_extension = File.extname(original_filename)
    plate_id = ""
    csv_data = []
  
    if file_extension == '.csv'
      # Handle comma-separated CSV
      CSV.foreach(file.path, encoding: 'UTF-8') do |row|
        row[0] = "Well positions" if csv_data.empty?
        plate_id = row[1] if row[1] && !row[1].strip.empty?
        csv_data << row
      end
    else
      # Handle tab-separated files (.txt, .tsv, .asc)
      File.open(file.path, 'r:ISO-8859-1') do |f|
        f.each_line.with_index do |line, index|
          line_utf8 = line.encode('UTF-8', 'ISO-8859-1', invalid: :replace, replace: '')
          values = line_utf8.chomp.gsub(/\x00/, '').split("\t")
          values[0] = "Well positions" if index == 0
          plate_id = values[1] if values[1] && !values[1].strip.empty?
          csv_data << values
        end
      end
    end

    # Normalize filename to .txt
    new_filename = "#{File.basename(plate_id, '.*')}.txt"
    txt_file = directory_path.join(new_filename)

    File.open(txt_file, 'w') do |f|
      csv_data.each do |row|
        f.puts row.join("\t")
      end
    end

    @plate_id = plate_id 
    txt_file.to_s
  end
end

