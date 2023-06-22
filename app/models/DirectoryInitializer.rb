class DirectoryInitializer
  def self.create_upload_directory
    upload_dir = Rails.root.join('private', 'uploads', 'userexpt')

    # Create the main upload directory if it doesn't exist
    FileUtils.mkdir_p(upload_dir) unless Dir.exist?(upload_dir)

    # Create the data subdirectory if it doesn't exist
    data_dir = File.join(upload_dir, 'data')
    FileUtils.mkdir_p(data_dir) unless Dir.exist?(data_dir)

    # Create the mapping subdirectory if it doesn't exist
    mapping_dir = File.join(upload_dir, 'mapping')
    FileUtils.mkdir_p(mapping_dir) unless Dir.exist?(mapping_dir)
  end
end

