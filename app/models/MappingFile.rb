class MappingFile
  attr_reader :file_path, :error_message

  def initialize(file, data_file_name)
    @file = file
    valid_extensions = ['.txt', '.asc', '.tsv', '.csv']
    if valid_extensions.include?(File.extname(file.original_filename))
      print("Valid mapping file detected: #{file.original_filename}\n")
      @file_path = save_file(file, data_file_name)
    else
      @error_message = 'Invalid mapping file format. Please ensure that your mapping file is a .asc, .txt, .tsv, or .csv file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path) 
  end
  
  private

  def save_file(file, data_file_name)
    directory_path = Rails.root.join('private', 'uploads', 'userexpt', 'mapping')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)
  
    original_filename = file.original_filename
    file_extension = File.extname(original_filename)
  
    if file_extension.downcase == '.txt' || file_extension.downcase == '.asc' || file_extension.downcase == '.tsv'
      csv_data = []
  
      File.open(file.path, 'r') do |file|
        file.each_line.with_index do |line,index|
          # Split each line using the tab character as the delimiter
          values = line.chomp.encode('UTF-8', 'ISO-8859-1').split("\t")
          if index == 0
            values[0] = "Well positions"
          end
          csv_data << values
          
        end
      end
  
      # Write the CSV data to a new CSV file
      new_filename = "#{File.basename(data_file_name, '.*')}-mapping.csv"
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
