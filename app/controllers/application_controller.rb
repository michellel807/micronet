class ApplicationController < ActionController::Base
    helper_method :current_admin

    def current_admin
      @current_admin ||= Admin.find_by(id: session[:admin_id]) if session[:admin_id]
    end

    private

    def mapping_columns(file_paths)
      first_file_path = Array(file_paths).first
      return [] unless first_file_path.present?

      file_data = File.read(first_file_path, encoding: "iso-8859-1:utf-8")
      file_data.lines.first.to_s.chomp.split("\t")
    end
end
