# app/jobs/job_analyzer.rb

class JobAnalyzer < Struct.new(:job_id, :chart_types, :pool_replicates, :pool_options_string, :test_finalsubset, :hypothesis, :gp_pool_by_column, :gp_subset_choice, :gp_finalsubset, :compare_parameters_pool, :compare_finalsubset, :heatmap_value, :heatmap_x, :heatmap_y)
  def perform
    job = Job.find(job_id)
    job.analyze(chart_types, pool_replicates, pool_options_string, test_finalsubset, hypothesis, gp_pool_by_column, gp_subset_choice, gp_finalsubset, compare_parameters_pool, compare_finalsubset, heatmap_value, heatmap_x, heatmap_y)
  end
end

