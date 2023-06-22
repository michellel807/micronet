class MappingFile
  attr_reader :file_path

  def initialize(file)
    if ['.txt', '.asc', '.csv'].include?(File.extname(file.original_filename).downcase)
      @file_path = save_file(file)
    else
      raise ArgumentError, 'Invalid data file format'
    end
  end

  def valid?
    !@file_path.nil? && File.exist?(@file_path) && File.file?(@file_path)
  end

  private

  def save_file(file)
    file_path = Rails.root.join('private', 'uploads', 'userexpt', 'mapping', file.original_filename)

    File.open(file_path, 'wb') do |f|
      f.write(file.read)
    end

    file_path.to_s
  end
end

