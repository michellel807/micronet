class SelectanalysesController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @selected_chart_types = [] # Initialize the selected_chart_types variable
    @charts_data = {}
    @mapping_file_paths = session[:mapping_file_paths]
    if @mapping_file_paths.present?
      first_file_path = @mapping_file_paths.first
      file_data = File.read(first_file_path, encoding: 'iso-8859-1:utf-8')
      @file_data_json = file_data.to_json
      @columns = file_data.lines.first.chomp.split("\t")
    end
    @pool_options = @columns.reject { |column| column.downcase.include?('well') }
    session[:columns] = params[:columns]
  end
end