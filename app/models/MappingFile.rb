class MappingFile
  attr_reader :file_path, :error_message

  def initialize(file)
    @file = file
    if File.extname(file.original_filename) == '.txt'
      @file_path = save_file(file)
    else
      @error_message = 'Invalid mapping file format. Please ensure that your mapping file is a .txt file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path) && File.extname(@file.original_filename) == '.txt'
  end
  
  private

  def save_file(file)
    directory_path = Rails.root.join('private', 'uploads', 'userexpt', 'mapping')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)

    file_path = directory_path.join(file.original_filename)

    File.open(file_path, 'wb') do |f|
      f.write(file.read)
    end

    file_path.to_s
  end
end
