class ApplicationController < ActionController::Base
    helper_method :current_admin

    def current_admin
      @current_admin ||= Admin.find_by(id: session[:admin_id]) if session[:admin_id]
    end

    private

    def require_upload_workspace
      @user = User.find_by(id: session[:user_id])
      token = session[:upload_token]
      @workspace = UploadWorkspace.find(token) if @user
      if @workspace
        @workspace.with_lock {} # Validate expiry and mark this session active.
      else
        upload_workspace_expired
      end
    rescue UploadWorkspace::Expired
      upload_workspace_expired
    end

    def lock_upload_workspace
      @workspace.with_lock { yield }
    rescue UploadWorkspace::Expired
      upload_workspace_expired
    end

    def upload_workspace_expired
      # A second click may arrive while the first submission is committing.
      # Wait for its user lock before treating the moved workspace as expired.
      if @user && session[:upload_token].present?
        @user.with_lock { @job = @user.jobs.find_by(upload_token: session[:upload_token]) }
      end
      if @job
        session[:current_user_id] = @job.id
        redirect_to "/generate"
      else
        redirect_to root_path, alert: "Please begin a new analysis. Your temporary uploads are no longer available."
      end
    end

    def mapping_columns(file_paths)
      first_file_path = Array(file_paths).first
      return [] unless first_file_path.present?

      file_data = File.read(first_file_path, encoding: "iso-8859-1:utf-8")
      file_data.lines.first.to_s.chomp.split("\t")
    end
end
