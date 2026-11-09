require "test_helper"
require "open3"

class RnaSeqPipelineTest < ActiveSupport::TestCase
  EXAMPLES = Rails.root.join("lib", "examplefiles", "rnaseq")
  RSCRIPT_AVAILABLE = system(ENV.fetch("RSCRIPT_EXECUTABLE", "Rscript"), "--version", out: File::NULL, err: File::NULL)

  setup do
    ActionMailer::Base.deliveries.clear
    @user = User.create!(email: "rnaseq-pipeline-#{SecureRandom.hex(6)}@example.com")
    configuration = RnaSeq::Configuration.new(
      counts_file: "counts.tsv", metadata_file: "sample_metadata.tsv",
      deseq2: { reference_level: "control", test_level: "treated" }
    )
    @job = Job.create!(user: @user, status: "Job submitted", analysis_type: "rnaseq",
                       analysis_config: configuration.to_h, submission_options: configuration.summary)
    FileUtils.mkdir_p(@job.rnaseq_input_dir)
    FileUtils.cp([EXAMPLES.join("counts.tsv"), EXAMPLES.join("sample_metadata.tsv")], @job.rnaseq_input_dir)
  end

  teardown do
    @job.clear_uploads!
  end

  test "a successful run emails one zip holding every result file" do
    require_rscript
    RnaSeq::Pipeline.new(@job).run

    assert_equal "Completed", @job.reload.status
    assert_not_nil @job.start_time
    assert_not_nil @job.end_time
    message = ActionMailer::Base.deliveries.sole
    assert_equal [@user.email], message.to
    assert_equal "Schmid Lab RNA-seq Analysis: Processed Data [Job ##{@job.job_number}]", message.subject
    zip_name = "rnaseq_results_job#{@job.job_number}.zip"
    assert_equal [zip_name], message.attachments.map(&:filename)

    folder = "rnaseq_results_job#{@job.job_number}"
    expected = %w[
      README.txt manifest.json deseq2_results.tsv significant_genes.tsv size_factors.tsv normalized_counts.tsv
      vst_all.tsv vst_significant.tsv pca.pdf pca_coordinates.tsv ma_plot.pdf volcano_plot.pdf
    ].map { |name| "#{folder}/#{name}" }
    assert_equal expected.sort, zip_entries(message.attachments.first.decoded).sort

    manifest = JSON.parse(@job.rnaseq_results_dir.join("manifest.json").read)
    assert_includes message.text_part.body.decoded, "Significant genes: #{manifest['genes']['significant']}"
  end

  test "failed plots still deliver the tables, with a warning" do
    require_rscript
    run_command = @job.method(:run_cancellable_command)
    plots_fail = ->(*command) { command.any? { |part| part.to_s.end_with?("plot_results.py") } ? false : run_command.call(*command) }
    @job.stub(:run_cancellable_command, plots_fail) { RnaSeq::Pipeline.new(@job).run }

    assert_equal "Completed with warnings", @job.reload.status
    body = ActionMailer::Base.deliveries.sole.text_part.body.decoded
    assert_includes body, "Plots: The plots could not be drawn"
    assert @job.rnaseq_results_dir.join("significant_genes.tsv").file?
  end

  test "results too large to email are replaced by the summary files" do
    require_rscript
    ENV["RNASEQ_ATTACHMENT_LIMIT_MB"] = "0.01"
    RnaSeq::Pipeline.new(@job).run

    assert_equal "Completed with warnings", @job.reload.status
    message = ActionMailer::Base.deliveries.sole
    assert_equal %w[README.txt significant_genes.tsv pca.pdf ma_plot.pdf volcano_plot.pdf], message.attachments.map(&:filename)
    assert_includes message.text_part.body.decoded, "are too large to email"
  ensure
    ENV.delete("RNASEQ_ATTACHMENT_LIMIT_MB")
  end

  test "an input problem fails the job and tells the user what to fix" do
    fake_r = lambda do |*command|
      out = Pathname(command[command.index("--out") + 1])
      out.join("manifest.json").write({ status: "failed", error_type: "input_error", message: "Duplicate gene IDs: gene7" }.to_json)
      false
    end
    @job.stub(:run_cancellable_command, fake_r) { RnaSeq::Pipeline.new(@job).run }

    assert_equal "Failed", @job.reload.status
    message = ActionMailer::Base.deliveries.sole
    assert_equal "Schmid Lab RNA-seq Analysis: Job Failed [Job ##{@job.job_number}]", message.subject
    # The existing failure email shows the message in its HTML part only.
    assert_includes message.html_part.body.decoded, "Your RNA-seq files could not be analyzed: Duplicate gene IDs: gene7"
  end

  test "an analysis killed for memory gets the memory explanation" do
    killed = ->(*) { system("sh", "-c", "kill -KILL $$"); false }
    @job.stub(:run_cancellable_command, killed) { RnaSeq::Pipeline.new(@job).run }

    assert_equal "Failed", @job.reload.status
    assert_includes ActionMailer::Base.deliveries.sole.html_part.body.decoded, "ran out of memory"
  end

  test "cancellation during the analysis stops without a failure email" do
    cancel = lambda do |*|
      Job.where(id: @job.id).update_all(status: "Cancelled")
      raise Job::Cancelled
    end
    @job.stub(:run_cancellable_command, cancel) { RnaSeq::Pipeline.new(@job).run }

    assert_equal "Cancelled", @job.reload.status
    assert_empty ActionMailer::Base.deliveries
  end

  test "an already cancelled job never starts" do
    @job.update!(status: "Cancelled")
    @job.stub(:run_cancellable_command, ->(*) { flunk "no command should run" }) { RnaSeq::Pipeline.new(@job).run }

    assert_equal "Cancelled", @job.reload.status
    assert_nil @job.start_time
    assert_empty ActionMailer::Base.deliveries
  end

  test "an unreadable saved configuration fails the job instead of leaving it queued" do
    @job.update!(analysis_config: { "counts_file" => "counts.tsv" })
    RnaSeq::Pipeline.new(@job).run

    assert_equal "Failed", @job.reload.status
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  private

  def zip_entries(bytes)
    list = "import io, sys, zipfile; print(*zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read())).namelist(), sep=chr(10))"
    output, status = Python.exec("-c", list) { |*command| Open3.capture2(*command, stdin_data: bytes, binmode: true) }
    assert status.success?
    output.split("\n")
  end

  def require_rscript
    skip "Rscript is not installed; run these tests in the MicroNet Docker image." unless RSCRIPT_AVAILABLE
  end
end
