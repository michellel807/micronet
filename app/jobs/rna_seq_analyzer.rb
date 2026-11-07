# app/jobs/rna_seq_analyzer.rb

# The job's settings are read from Job#analysis_config, so this queue entry
# needs only the ID. RnaSeq::Pipeline does the work.
class RnaSeqAnalyzer < Struct.new(:job_id)
  def perform
    job = Job.find(job_id)
    if job.status == "Cancelled"
      Rails.logger.info("RnaSeqAnalyzer skipping cancelled job_id=#{job_id}")
      return
    end

    RnaSeq::Pipeline.new(job).run
    Rails.logger.info("RnaSeqAnalyzer#perform finish job_id=#{job_id} status=#{job.reload.status}")
  end
end
