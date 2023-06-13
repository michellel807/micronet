class OdUploader < AttachmentUploader
    # Renames the uploaded file to "od.csv"
  def filename
    "od.csv" if original_filename.present?
  end

  def extension_white_list
    %w[csv]
  end
end
