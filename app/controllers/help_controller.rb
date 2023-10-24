# app/controllers/help_controller.rb
class HelpController < ApplicationController
    def index
    end
  
    def download_file
        file_path = Rails.root.join('lib', 'examplefiles', params[:file_name] + '.asc')
        send_file file_path, filename: params[:file_name] + '.asc'
      end
    
      def download_mapping_file
        file_path = Rails.root.join('lib', 'examplefiles', params[:file_name] + '.txt')
        send_file file_path, filename: params[:file_name] + '.txt'
      end
    

  end
  