require 'csv'

class DataFile
  attr_reader :file_path, :error_message

  def initialize(file)
    @file = file
    @file_path = save_file(file)
    # if File.extname(file.original_filename) == '.asc'
    #   @file_path = save_file(file)
    # else
    #   @error_message = 'Invalid data file format. Please ensure that your data file is a .asc file and try again.'
    # end
  end

  def valid?
    # @file_path && File.exist?(@file_path) && File.file?(@file_path) && File.extname(@file.original_filename) == '.asc'
    @file_path && File.exist?(@file_path) && File.file?(@file_path)
  end
  
  private
  
  def save_file(file)
    directory_path = Rails.root.join('private', 'uploads', 'userexpt', 'data')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)
  
    original_filename = file.original_filename
    file_extension = File.extname(original_filename)
  
    if file_extension.downcase == '.txt' || file_extension.downcase == '.asc'
      csv_data = []
  
      File.open(file.path, 'r:ISO-8859-1') do |file|
        file.each_line.with_index do |line, index|
          # Split each line using the tab character as the delimiter
          values = line.chomp.encode('UTF-8', 'ISO-8859-1').split("\t")
          if index == 0
            # Change the first column's first row cell to a different word
            values[0] = "Well positions"
          end
          csv_data << values
          
        end
      end
  
      # Write the CSV data to a new CSV file
      new_filename = "#{File.basename(original_filename, '.*')}.csv"
      csv_file = directory_path.join(new_filename)
  
      CSV.open(csv_file, 'w') do |csv|
        csv_data.each do |row|
          csv << row
        end
      end
  
      file_path = csv_file
    else
      # If the file doesn't have a .txt or .asc extension, simply copy it to the directory
      file_path = directory_path.join(original_filename)
      File.open(file_path, 'wb') do |f|
        f.write(file.read)
      end
    end
  
    file_path.to_s
  end
end