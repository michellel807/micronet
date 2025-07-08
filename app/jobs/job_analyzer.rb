# app/jobs/job_analyzer.rb
class JobAnalyzer < Struct.new(:job_id, :chart_types, :pool_replicates, :pool_options, :finalsubset, :hypothesis, :compare_parameters_pool, :finalsubset_pooled)
  def perform
    job = Job.find(job_id)
    job.analyze(chart_types, pool_replicates, pool_options, finalsubset, hypothesis, compare_parameters_pool, finalsubset_pooled)
  end
end

