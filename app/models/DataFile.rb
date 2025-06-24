require 'csv'

class DataFile
  attr_reader :file_path, :error_message

  def initialize(file, mapping_path)
    @file = file
    valid_extensions = ['.txt', '.asc', '.tsv', '.csv']
    if valid_extensions.include?(File.extname(file.original_filename).downcase)
      @file_path = save_file(file, mapping_path)
    else
      @error_message = 'Invalid data file format. Please ensure that your data file is a .asc, .txt, .tsv, or .csv file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path)
  end
  
  private
  
  def save_file(file, mapping_path)
    directory_path = Rails.root.join('private', 'uploads', 'userexpt', 'data')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)
  
    original_filename = file.original_filename
    file_extension = File.extname(original_filename).downcase
    csv_data = []
  
    if file_extension == '.csv'
      # Parse CSV file and convert to tab-separated format
      CSV.foreach(file.path, encoding: 'UTF-8') do |row|
        csv_data << row
      end
    else
      # Handle .txt, .tsv, .asc as tab-separated files
      File.open(file.path, "r:ISO-8859-1") do |f|
        f.each_line.with_index do |line, index|
          new_line = line.encode('UTF-8', 'ISO-8859-1', invalid: :replace, replace: '')
          cleaned_line = new_line.gsub(/\x00/, '')
          values = cleaned_line.chomp.split("\t")
          values[0] = "Well positions" if index == 0
          csv_data << values
        end
      end
    end

    # Save everything as .txt (tab-separated)
    new_filename = "#{File.basename(mapping_path, '.*')}.txt"
    txt_file = directory_path.join(new_filename)

    File.open(txt_file, 'w') do |f|
      csv_data.each { |row| f.puts row.join("\t") }
    end

    txt_file.to_s
  end
end
