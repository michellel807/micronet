class ReviewController < ApplicationController
  require 'json'
  require 'open3'

  skip_before_action :verify_authenticity_token

  def index
    @job = Job.find(session[:current_user_id])
    @user = User.find(@job.user_id)

    @data_file_paths = session[:data_file_paths]
    @usr_data_file_paths = session[:usr_data_file_paths]
    @mapping_file_paths = session[:mapping_file_paths]
    @usr_mapping_file_paths = session[:usr_mapping_file_paths]
    @meta_file_path = session[:meta_file_path]
    @usr_meta_file_path = session[:usr_meta_file_path]
    @interval_file_path = session[:interval_file_path]
    @usr_interval_file_path = session[:usr_interval_file_path]
    
    
    @usr_data_file_names = @usr_data_file_paths.map { |file_path| File.basename(file_path) }
    @usr_mapping_file_names = @usr_mapping_file_paths.map { |file_path| File.basename(file_path) }
    @usr_meta_file_name = File.basename(@usr_meta_file_path) if @usr_meta_file_path.present?
    @usr_interval_file_name = File.basename(@usr_interval_file_path) if @usr_interval_file_path.present?

    # Validate that each data file has exactly 96 wells if "raw_data" was selected.
    session[:chart_types] = params[:chart_types] || []
    if session[:chart_types]&.include?("raw_data")
      invalid_files = []

      data_paths = Array(@data_file_paths)
      mapping_paths = Array(@mapping_file_paths)

      data_paths.each_with_index do |data_file_path, index|
        mapping_file_path = mapping_paths[index]
        result = compare_file_counts(data_file_path, mapping_file_path)
        data_well_count = result&.dig("data_well_count")
        invalid_files << File.basename(data_file_path) unless data_well_count == 96
      end

      puts "INVALID FILES: #{invalid_files.inspect}"
      unless invalid_files.empty?
        flash[:error] = "Each uploaded file must include 96 wells for Raw Data Plot analysis."
        redirect_to selectanalyses_path and return
      end
    end

    if @mapping_file_paths.present?
      first_file_path = @mapping_file_paths.first
      file_data = File.read(first_file_path, encoding: 'iso-8859-1:utf-8')
      @columns = file_data.lines.first.chomp.split("\t")
      @pool_options = @columns.reject { |column| column.downcase.include?('well') }
    end

      session[:pool_replicates] = params[:pool_replicates] || []
      session[:pool_options] = params[:pool_options] || []
      session[:compare_parameters_pool] = params[:column_pooled] || 'None'
      session[:email] = params[:email] || ""
      session[:data_files] = params[:data_files] || []
      session[:gp_pool_by_column] = params[:gp_pool_by_column] || "None"
      session[:gp_subset_choice] = params[:gp_subset_choice] || []
      session[:gp_subset_column] = params[:gp_subset_column] || "None"
      session[:gp_conditions] = params[:gp_conditions] || []
      session[:heatmap_value] = params[:heatmap_value] || 'None'
      session[:heatmap_x] = params[:heatmap_x] || 'None'
      session[:heatmap_y] = params[:heatmap_y] || 'None'
      puts "Pool_replicates is #{session[:pool_replicates]}"
      puts "Pool_options is #{session[:pool_options]}"
      puts "Compare parameters subset is #{session[:compare_parameters_pool]}"
      puts "GP pool by column: #{session[:gp_pool_by_column]}"
      puts "GP subset choice: #{session[:gp_subset_choice]}"
      puts "GP subset column: #{session[:gp_subset_column]}"
      puts "GP subset values: #{session[:gp_conditions].inspect}"
      puts "Heatmap value: #{session[:heatmap_value]}"
      puts "Heatmap x-axis: #{session[:heatmap_x]}"
      puts "Heatmap y-axis: #{session[:heatmap_y]}"

    permitted = params.permit!

    test_subset_params = permitted.to_h.select { |k, v| k.start_with?("test_subset_") && v.present? && !v.start_with?("Select a value") }
    compare_subset_params = permitted.to_h.select { |k, v| k.start_with?("pooled_subset_") && v.present? && !v.start_with?("Select a value") }

    test_final = test_subset_params.map { |k, v| "#{k.sub("test_subset_", "")}:#{v}" }.join(";")
    compare_final = compare_subset_params.map { |k, v| "#{k.sub("pooled_subset_", "")}:#{v}" }.join(";")
    session[:test_final] = test_final
    session[:compare_final] = compare_final
    
    # Test Hypothesis parameters
    @column_test = params[:column_test] || 'None'
    session[:column_test] = @column_test
    @condition1_test = params[:condition1_test] || 'None'
    @condition2_test = params[:condition2_test] || 'None'
    test_finalsubset = "'#{@column_test}:#{@condition1_test},#{@condition2_test};#{test_final}'"
    session[:test_finalsubset] = test_finalsubset
    
    # Compare Parameters parameters
    @column_pooled = params[:column_pooled] || 'None'
    session[:column_pooled] = @column_pooled
    @condition1_pooled = params[:condition1_pooled] || 'None'
    @condition2_pooled = params[:condition2_pooled] || 'None'
    compare_finalsubset = "'#{@column_pooled}:#{@condition1_pooled},#{@condition2_pooled};#{compare_final}'"
    session[:compare_finalsubset] = compare_finalsubset
    
    @hypothesis = "H0:Time;H1:Time+" + @column_test || 'None'
    @hypothesis = "'#{@hypothesis}'"
    session[:hypothesis] = @hypothesis
    session[:column_test] = @column_test
    puts "test_finalsubset is #{session[:test_finalsubset]}"
    puts "compare_finalsubset is #{session[:compare_finalsubset]}"
    puts "hypothesis is #{session[:hypothesis]}"

    @gp_pool_by_column = session[:gp_pool_by_column]
    @gp_pool_by_column = "'#{@gp_pool_by_column}'"
    @gp_subset_column = session[:gp_subset_column]
    @gp_conditions = session[:gp_conditions]
    @gp_subset_choice = session[:gp_subset_choice]
    gp_finalsubset = "'#{@gp_subset_column}:#{@gp_conditions.join(",")}'"
    session[:gp_finalsubset] = gp_finalsubset
    puts "GP final subset is #{session[:gp_finalsubset]}"

    @heatmap_value = session[:heatmap_value]
    @heatmap_x = session[:heatmap_x]
    @heatmap_y = session[:heatmap_y]
  end

  private

  def compare_file_counts(data_file_path, mapping_file_path)
    script_path = Rails.root.join("lib/scripts/otherscripts/comparedataandmapping.py").to_s
    command = [python_executable, script_path, "--json", data_file_path.to_s, mapping_file_path.to_s]
    stdout, stderr, status = Open3.capture3(*command)
    Rails.logger.debug("comparedataandmapping status=#{status.exitstatus} stdout=#{stdout.inspect} stderr=#{stderr.inspect}")
    JSON.parse(stdout)
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse comparedataandmapping JSON for #{data_file_path}: #{e.message}")
    nil
  rescue => e
    Rails.logger.error("Failed comparedataandmapping for #{data_file_path}: #{e.message}")
    nil
  end

  def python_executable
    preferred = "/opt/uvenv/bin/python"
    File.executable?(preferred) ? preferred : "python3"
  end
end
