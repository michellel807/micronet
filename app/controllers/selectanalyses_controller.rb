class SelectanalysesController < ApplicationController
  before_action :require_upload_workspace
  around_action :lock_upload_workspace

  def index
    # Set flag if returning from review
    session[:returning_from_review] = params[:returning_from_review] == 'true'

    # Restore selected chart types from session if available
    @selected_chart_types = session[:chart_types] || []
    @charts_data = {}
    @mapping_file_paths = session[:mapping_file_paths]
    
    if @mapping_file_paths.present?
      first_file_path = @mapping_file_paths.first
      file_data = File.read(first_file_path, encoding: 'iso-8859-1:utf-8')
      @file_data_json = file_data.to_json
      @columns = file_data.lines.first.chomp.split("\t")
    end
    
    @pool_options = @columns.reject { |column| column.downcase.include?('well') } if @columns.present?
    session[:columns] = params[:columns]

    # Restore analysis-specific parameters from session
    @gp_pool_by_column = session[:gp_pool_by_column]
    @gp_subset_column = session[:gp_subset_column]
    @gp_conditions = session[:gp_conditions] || []
    @gp_subset_filters = GpConfiguration.filters(session)
    @gp_pool_columns = GpConfiguration.pool_columns(session)
    @gp_pool_replicates = session[:gp_pool_replicates].presence || (@gp_pool_columns.any? ? "yes" : "no")
    @pool_replicates = session[:pool_replicates]
    @pool_options_selected = session[:pool_options] || []
    @heatmap_value = session[:heatmap_value]
    @heatmap_x = session[:heatmap_x]
    @heatmap_y = session[:heatmap_y]
    @comparison_selections = session[:comparison_selections] || {}
    @column_test = session[:column_test]
    @column_pooled = session[:column_pooled]
  end
end
