class MetaUploader < AttachmentUploader
  # Renames the uploaded file to "meta.csv"
  def filename
    "meta.csv" if original_filename.present?
  end

  def extension_white_list
    %w[csv]
  end
end
