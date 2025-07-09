class FilesController < ApplicationController
  def download
    filename = params[:filename]
    file_path = Rails.root.join('private', 'uploads', 'userexpt', 'figures', filename)
    if File.exist?(file_path)
      send_file file_path, disposition: 'attachment'
    else
      render plain: "File not found", status: :not_found
    end
  end
end 