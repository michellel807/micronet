require 'csv'

class DataFile
  attr_reader :file_path, :error_message

  def initialize(file, mapping_path)
    @file = file
    valid_extensions = ['.txt', '.asc', '.tsv', '.csv']
    if valid_extensions.include?(File.extname(file.original_filename))
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
    file_extension = File.extname(original_filename)
  
    if file_extension.downcase == '.txt' || file_extension.downcase == '.asc' || file_extension.downcase == '.tsv'
      csv_data = []
  
      File.open(file.path, "r:ISO-8859-1") do |file|
        file.each_line.with_index do |line, index|
          # Remove or replace non-ASCII characters
          new_line = line.encode('UTF-8', 'ISO-8859-1', invalid: :replace, replace: '')
          cleaned_line = new_line.gsub!(/\x00/, '')
          # Split the cleaned line using the tab character as the delimiter
          values = cleaned_line.chomp.split("\t")
            if index == 0
              values[0] = "Well positions"
            end
    
            csv_data << values
        end
      end
  
      # Write the CSV data to a new CSV file
      new_filename = "#{File.basename(mapping_path, '.*')}.csv"
      csv_file = directory_path.join(new_filename)
  
      CSV.open(csv_file, 'w') do |csv|
        csv_data.each do |row|
          csv << row
        end
      end
  
      file_path = csv_file
    else
      # If the file doesn't have a .txt or .asc  or .tsv extension, simply copy it to the directory
      file_path = directory_path.join(original_filename)
      File.open(file_path, 'wb') do |f|
        f.write(file.read)
      end
    end
  
    file_path.to_s
  end
end