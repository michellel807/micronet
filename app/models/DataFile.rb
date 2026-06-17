require 'csv'

class DataFile
  attr_reader :file_path, :error_message

  def initialize(file, mapping_plate_id, upload_root:)
    @file = file
    @upload_root = upload_root
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
    csv_data = []
  
    if file_extension == '.csv'
      raw_data = CSV.read(file.path, encoding: 'UTF-8')
    else
      raw_data = []
      File.open(file.path, "r:ISO-8859-1") do |f|
        f.each_line do |line|
          new_line = line.encode('UTF-8', 'ISO-8859-1', invalid: :replace, replace: '')
          cleaned_line = new_line.gsub(/\x00/, '')
          values = cleaned_line.chomp.split("\t")
          raw_data << values
        end
      end
    end

    # Remove first line if it contains "Well"
    raw_data.shift if raw_data.first&.any? { |v| v.to_s.downcase.include?("well") }
    raw_data.first[0] = "Well positions" if raw_data.first

    # Remove last line if it contains "Date"
    i = raw_data.rindex { |row| row.any?(&:present?) }
    raw_data.delete_at(i) if i && raw_data[i].any? { |v| v.to_s.downcase.include?("date") }

    csv_data = raw_data

    # Save everything as .txt (tab-separated)
    new_filename = "#{File.basename(mapping_plate_id.to_s, '.*')}.txt"
    txt_file = directory_path.join(new_filename)

    File.open(txt_file, 'w') do |f|
      csv_data.each { |row| f.puts row.join("\t") }
    end

    txt_file.to_s
  end
end
