class ParameterController < ApplicationController
  skip_before_action :verify_authenticity_token
def index
  @mapping_file_paths = session[:mapping_file_paths]
  if @mapping_file_paths.present?
    first_file_path = @mapping_file_paths.first
    file_data = File.read(first_file_path, encoding: 'iso-8859-1:utf-8')
    @columns = file_data.lines.first.chomp.split("\t")
    @pool_options = @columns.reject { |column| column.downcase.include?('well') }
  end
  end
end

