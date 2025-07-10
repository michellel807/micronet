# app/jobs/job_analyzer.rb
<<<<<<< app/jobs/job_analyzer.rb
class JobAnalyzer < Struct.new(:job_id, :chart_types, :pool_replicates, :pool_options, :finalsubset, :hypothesis, :compare_parameters_pool, :finalsubset_pooled, :heatmap_params)
  def perform
    job = Job.find(job_id)
    job.analyze(chart_types, pool_replicates, pool_options, finalsubset, hypothesis, compare_parameters_pool, finalsubset_pooled, heatmap_params)
>>>>>>> app/jobs/job_analyzer.rb
  end
end

