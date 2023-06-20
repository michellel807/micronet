class SelectanalysesController < ApplicationController
  skip_before_action :verify_authenticity_token
  def index
  @selected_chart_types = [] # Initialize the selected_chart_types variable
  @charts_data = {}
end
end