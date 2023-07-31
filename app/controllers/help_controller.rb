# app/controllers/help_controller.rb
class HelpController < ApplicationController
    def index
    end
  
    def download_file
      file_name = params[:file_name]
      file_path = Rails.root.join('lib', 'examplefiles', file_name)
  
      send_file file_path, filename: file_name
    end
  end
  