# app/controllers/help_controller.rb
class HelpController < ApplicationController
  def index
  end

  def download_data_file
    send_example_file(params[:file_name], "data")
  end

  def download_mapping_file
    send_example_file(params[:file_name], "mapping")
  end

  def download_meta_file
    # Meta file is also in the "mapping" folder
    send_example_file(params[:file_name], "mapping")
  end

  def download_interval_file
    # Interval file is in the "parameter" folder
    send_example_file(params[:file_name], "parameters")
  end

  private

  def send_example_file(file_name, folder)
    file_path = Rails.root.join("lib", "examplefiles", folder, "#{file_name}.txt")
    if File.exist?(file_path)
      send_file file_path, filename: "#{file_name}.txt", disposition: 'attachment'
    else
      render plain: "File not found", status: :not_found
    end
  end
end