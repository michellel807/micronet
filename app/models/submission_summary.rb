# Build a snapshot from the validated session, excluding unselected analyses.
class SubmissionSummary
  ANALYSES = {
    "raw_data" => "Raw Data Plots (Per Well)",
    "gp_plot" => "Gaussian Process Plot",
    "fit_stats" => "Fit Statistics",
    "heatmap_plot" => "Heatmap Plot",
    "test-hypothesis" => "Test Hypothesis",
    "compare-parameters" => "Compare Growth"
  }.freeze

  def self.from_session(session)
    charts = Array(session[:chart_types])
    summary = {
      "Analyses" => charts.filter_map { |chart| ANALYSES[chart] }.join(", "),
      "Gaussian Process time step size" => session[:gp_time_step_size].presence || Job::DEFAULT_TSS
    }

    if charts.include?("gp_plot")
      summary["Gaussian Process subset"] = GpConfiguration.subset_description(session)
      summary["Gaussian Process pooling"] = GpConfiguration.pool_columns(session).presence&.join(", ") || "None"
    end
    if charts.include?("fit_stats")
      summary["Fit Statistics pooling"] = session[:pool_replicates] == "yes" ? Array(session[:pool_options]).join(", ") : "None"
    end
    if charts.include?("heatmap_plot")
      summary["Heatmap value"] = session[:heatmap_value]
      summary["Heatmap X axis"] = session[:heatmap_x]
      summary["Heatmap Y axis"] = session[:heatmap_y]
    end
    if charts.include?("test-hypothesis")
      summary["Hypothesis test variable"] = session[:column_test]
      summary["Hypothesis test conditions and subset"] = session[:test_finalsubset].to_s.delete_prefix("'").delete_suffix("'")
      summary["Hypothesis"] = session[:hypothesis].to_s.delete_prefix("'").delete_suffix("'")
    end
    if charts.include?("compare-parameters")
      summary["Compare Growth pooling"] = session[:compare_parameters_pool]
      summary["Compare Growth conditions and subset"] = session[:compare_finalsubset].to_s.delete_prefix("'").delete_suffix("'")
    end

    summary["Uploaded Files"] = {
      "Data Files" => filenames(session[:usr_data_file_paths]),
      "Mapping Files" => filenames(session[:usr_mapping_file_paths]),
      "Meta File" => filenames(session[:usr_meta_file_path]),
      "Interval File" => filenames(session[:usr_interval_file_path])
    }.reject { |_label, names| names.empty? }
    summary["Analyses To Run"] = charts.filter_map do |chart|
      case chart
      when "raw_data"
        ANALYSES[chart]
      when "gp_plot"
        pool = summary["Gaussian Process pooling"]
        pooling = pool == "None" ? "No pooling" : "Pooled by #{pool}"
        "Gaussian Process Plot (Subset on #{summary['Gaussian Process subset']}; #{pooling})"
      when "fit_stats"
        pooling = session[:pool_replicates] == "yes" ? "Pool by #{summary['Fit Statistics pooling']}" : "No pooling"
        "Fit Statistics (#{pooling})"
      when "heatmap_plot"
        "Heatmap Plot (Value: #{session[:heatmap_value]}, X: #{session[:heatmap_x]}, Y: #{session[:heatmap_y]})"
      when "test-hypothesis"
        "Test Hypothesis (Test on #{session[:column_test]}; Conditions and subset: #{summary['Hypothesis test conditions and subset']}; #{summary['Hypothesis']})"
      when "compare-parameters"
        "Compare Growth (Compare by #{session[:compare_parameters_pool]}; Conditions and subset: #{summary['Compare Growth conditions and subset']})"
      end
    end

    summary
  end

  def self.filenames(paths)
    Array(paths).reject(&:blank?).map { |path| File.basename(path.to_s) }
  end
end
