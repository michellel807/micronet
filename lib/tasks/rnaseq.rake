# Submits the example RNA-seq dataset without the web pages (RnaSeqController),
# for trying the pipeline from the command line.
namespace :rnaseq do
  desc "Queue the example RNA-seq dataset (lib/examplefiles/rnaseq) for EMAIL; a jobs:work worker emails the results"
  task :submit_example, [:email] => :environment do |_task, args|
    email = args[:email].presence || abort('Usage: bin/rails "rnaseq:submit_example[you@example.com]"')
    user = User.find_or_create_by!(email: email)
    workspace = UploadWorkspace.create!
    examples = Rails.root.join("lib", "examplefiles", "rnaseq")
    FileUtils.mkdir_p(workspace.rnaseq_input_dir)
    FileUtils.cp([examples.join("counts.tsv"), examples.join("sample_metadata.tsv")], workspace.rnaseq_input_dir)

    configuration = RnaSeq::Configuration.new(
      counts_file: "counts.tsv", metadata_file: "sample_metadata.tsv",
      original_filenames: { counts: "counts.tsv", metadata: "sample_metadata.tsv" },
      deseq2: { reference_level: "control", test_level: "treated" }
    )
    job, = JobSubmission.call(user: user, workspace: workspace, choices: configuration, analysis_type: "rnaseq")
    job.sendconfirm
    puts "Queued RNA-seq job ##{job.job_number} for #{email}."
  rescue JobSubmission::LimitReached
    workspace&.discard!
    abort "#{email} already has #{Job::MAX_ACTIVE_JOBS_PER_USER} jobs queued or running."
  end
end
