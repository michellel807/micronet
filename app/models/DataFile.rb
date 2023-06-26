class DataFile
  attr_reader :file_path, :error_message

  def initialize(file)
    @file = file
    if File.extname(file.original_filename) == '.asc'
      @file_path = save_file(file)
    else
      @error_message = 'Invalid data file format. Please ensure that your data file is a .asc file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path) && File.extname(@file.original_filename) == '.asc'
  end
  
  private

  def save_file(file)
    directory_path = Rails.root.join('public', 'uploads', 'userexpt', 'data')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)

    file_path = directory_path.join(file.original_filename)

    File.open(file_path, 'wb') do |f|
      f.write(file.read)
    end

    file_path.to_s
  end
end
