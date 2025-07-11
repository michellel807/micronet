# app/jobs/job_analyzer.rb
class JobAnalyzer < Struct.new(:job_id, :chart_types, :pool_replicates, :pool_options, :finalsubset, :hypothesis, :gp_pool_by_column, :gp_subset_choice, :gp_finalsubset)
  def perform
    job = Job.find(job_id)
    job.analyze(chart_types, pool_replicates, pool_options_string, finalsubset, hypothesis, gp_pool_by_column, gp_subset_choice, gp_finalsubset)
  end
end

