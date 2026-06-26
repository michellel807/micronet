class FilesController < ApplicationController
  def serve_image
    filename = params[:filename]
    current_job = Job.find_by(id: session[:current_user_id])
    return head :not_found unless current_job

    file_path = current_job.figures_dir.join(filename)
    if File.exist?(file_path) && File.file?(file_path)
      send_file file_path, disposition: 'inline'
    else
      head :not_found
    end
  end

  def download
    filename = params[:filename]
    current_job = Job.find_by(id: session[:current_user_id])
    return render plain: "File not found", status: :not_found unless current_job

    file_path = current_job.figures_dir.join(filename)
    if File.exist?(file_path)
      send_file file_path, disposition: 'attachment'
    else
      render plain: "File not found", status: :not_found
    end
  end
end 
