# app/jobs/job_analyzer.rb
class JobAnalyzer < Struct.new(:job_id, :chart_types, :pool_replicates, :pool_options)
  def perform
    job = Job.find(job_id)
    job.analyze(chart_types, pool_replicates, pool_options)
  end
end

