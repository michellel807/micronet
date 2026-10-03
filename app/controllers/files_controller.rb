class FilesController < ApplicationController
  def download
    serve_figure_file(disposition: "attachment")
  end

  def serve_image
    serve_figure_file(disposition: "inline")
  end

  private

  def serve_figure_file(disposition:)
    job = find_job_for_file_request
    filename = safe_filename(params[:filename])

    return render_not_found if job.nil? || filename.nil?

    file_path = job.figures_dir.join(filename).cleanpath
    return render_not_found unless file_path.to_s.start_with?(job.figures_dir.to_s + File::SEPARATOR)
    return render_not_found unless File.exist?(file_path) && File.file?(file_path)

    send_file file_path, filename: filename, disposition: disposition
  end

  def find_job_for_file_request
    job_id = params[:job_id].presence || session[:current_user_id]
    return nil if job_id.blank?

    Job.find_by(id: job_id)
  end

  def safe_filename(raw_filename)
    filename = raw_filename.to_s
    return nil if filename.blank?
    return nil if filename.include?(File::SEPARATOR) || filename.include?("\\")
    return nil if filename.include?("..")
    return nil if filename != File.basename(filename)

    filename
  end

  def render_not_found
    render plain: "File not found", status: :not_found
  end
end
