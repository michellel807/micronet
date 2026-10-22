module UploadDirectories
  def self.root
    configured = Rails.configuration.x.uploads_root
    configured = configured.call if configured.respond_to?(:call)
    configured || Rails.root.join("private", "uploads")
  end

  def data_dir = upload_root.join("data")
  def mapping_dir = upload_root.join("mapping")
  def summary_dir = upload_root.join("summary")
  def derived_dir = upload_root.join("derived")
  def models_dir = upload_root.join("models")
  def figures_dir = upload_root.join("figures")
  def parameters_dir = upload_root.join("parameters")
  def pair_metadata_path = upload_root.join("pair_metadata.json")

  def ensure_upload_directories!
    [upload_root, data_dir, mapping_dir, parameters_dir, figures_dir, summary_dir, derived_dir, models_dir].each { |directory| FileUtils.mkdir_p(directory) }
  end

  def clear_uploads!
    FileUtils.rm_rf(upload_root)
  end
end
