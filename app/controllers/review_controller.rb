class ReviewController < ApplicationController
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

    if @mapping_file_paths.present?
      first_file_path = @mapping_file_paths.first
      file_data = File.read(first_file_path, encoding: 'iso-8859-1:utf-8')
      @columns = file_data.lines.first.chomp.split("\t")
      @pool_options = @columns.reject { |column| column.downcase.include?('well') }

      session[:pool_replicates] = params[:pool_replicates] || []
      session[:pool_options] = params[:pool_options] || []
      session[:chart_types] = params[:chart_types] || []
      puts "session[:chart_types] is #{session[:chart_types]}"
      session[:email] = params[:email] || ""
      session[:data_files] = params[:data_files] || []
    end
    subsetoptions = CSV.read(@mapping_file_paths[0], col_sep: "\t")[0]
    subsetoptions.keep_if {|option| params[option] != "Select a value for #{option}" && params[option] !=nil }
    final = {}
    subsetoptions.map{|option| final[option]=params[option]}
    final = final.map { |key, value| "#{key}:#{value}" }.join(",")
    @column = params[:column] || 'None'
    @condition1 = params[:condition1]
    @condition2 = params[:condition2]
    session[:subsetoptions] = subsetoptions
    finalsubset = "'#{@column}:#{@condition1},#{@condition2};#{final}'"
    session[:finalsubset] = finalsubset
    @hypothesis = "H0:Time;H1:Time+" + @column || 'None'
    @hypothesis = "'#{@hypothesis}'"
    session[:hypothesis] = @hypothesis
    session[:column] = @column
    puts "finalsubset is #{session[:finalsubset]}"
    puts "hypothesis is #{session[:hypothesis]}"
  end
end
