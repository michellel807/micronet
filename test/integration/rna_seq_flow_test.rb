require "test_helper"

class RnaSeqFlowTest < ActionDispatch::IntegrationTest
  EXAMPLES = Rails.root.join("lib/examplefiles/rnaseq")

  setup do
    @email = "rnaseq-flow@example.com"
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    User.find_by(email: @email)&.jobs&.each(&:clear_uploads!)
    UploadWorkspace.find(session[:upload_token])&.clear_uploads! if session
  end

  def upload_file(name, directory = EXAMPLES)
    Rack::Test::UploadedFile.new(directory.join(name), "text/tab-separated-values")
  end

  def start
    post "/", params: { email: @email, analysis_type: "rnaseq" }
    assert_redirected_to rnaseq_upload_path
  end

  def upload_examples
    post rnaseq_upload_path, params: { counts_file: upload_file("counts.tsv"), metadata_file: upload_file("sample_metadata.tsv") }
    assert_redirected_to rnaseq_configure_path
  end

  def workspace
    UploadWorkspace.find(session[:upload_token])
  end

  test "upload, choose a comparison, review and submit queue one RNA-seq job" do
    start
    follow_redirect!
    assert_response :success
    assert_select "h1", "RNA-seq: Upload Files"
    assert_select ".step-name", "Choose Comparison"

    assert_no_difference "Job.count" do
      upload_examples
      follow_redirect!
      assert_response :success
      assert_select "select#condition_column option[selected]", "condition"
      assert_select "select#reference_level option[value=control]", "control (4 samples)"

      post rnaseq_configure_path, params: {
        condition_column: "condition", reference_level: "control", test_level: "treated",
        alpha: "0.1", lfc_threshold: "0", lfc_test: "posthoc", samples_in_model: "all"
      }
      assert_redirected_to rnaseq_review_path
      follow_redirect!
      assert_response :success
      assert_includes response.body, "control (reference): 4; treated: 4"
      assert_includes response.body, "adjusted p-value &lt; 0.1"
      assert_includes response.body, "counts.tsv"
    end

    token = session[:upload_token]
    assert_difference ["Job.count", "Delayed::Job.count"], 1 do
      post rnaseq_submit_path
      assert_redirected_to "/generate"
    end

    job = Job.find_by!(upload_token: token)
    assert_equal "rnaseq", job.analysis_type
    assert_equal({ "condition_column" => "condition", "reference_level" => "control", "test_level" => "treated", "alpha" => 0.1 },
                 job.analysis_config["deseq2"])
    assert_equal({ "counts" => "counts.tsv", "metadata" => "sample_metadata.tsv" }, job.analysis_config["original_filenames"])
    assert job.rnaseq_input_dir.join(job.analysis_config["counts_file"]).file?
    assert job.rnaseq_input_dir.join(job.analysis_config["metadata_file"]).file?
    assert_not UploadWorkspace.find(token)
    assert_includes ActionMailer::Base.deliveries.last.subject, "[Job ##{job.id}]"

    follow_redirect!
    assert_response :success

    assert_no_difference ["Job.count", "Delayed::Job.count"] do
      post rnaseq_submit_path
    end
    assert_redirected_to "/generate"
  end

  test "default settings are left to the R script" do
    start
    upload_examples
    post rnaseq_configure_path, params: {
      condition_column: "condition", reference_level: "control", test_level: "treated",
      alpha: "0.05", lfc_threshold: "0", lfc_test: "posthoc", samples_in_model: "all"
    }
    assert_redirected_to rnaseq_review_path
    assert_equal({ "condition_column" => "condition", "reference_level" => "control", "test_level" => "treated" },
                 session[:rnaseq_config]["deseq2"])
  end

  test "mismatched files are rejected and keep the previously saved files" do
    start
    upload_examples
    Dir.mktmpdir do |directory|
      directory = Pathname.new(directory)
      File.write(directory.join("bad_metadata.tsv"), "sample\tcondition\nsomeone_else\tcontrol\n")
      post rnaseq_upload_path, params: { metadata_file: upload_file("bad_metadata.tsv", directory) }
    end
    assert_response :unprocessable_content
    assert_includes response.body, "sample names must match"
    assert_includes response.body, "sample_metadata.tsv"
    assert_equal %w[counts.tsv metadata.tsv], workspace.rnaseq_input_dir.children.map { |path| path.basename.to_s }.sort

    get rnaseq_configure_path
    assert_response :success
  end

  test "both files are required and only text table formats are accepted" do
    start
    post rnaseq_upload_path, params: {}
    assert_response :unprocessable_content
    assert_includes response.body, "Please choose a count matrix and a sample sheet"

    post rnaseq_upload_path, params: { counts_file: upload_file("counts.tsv") }
    assert_response :unprocessable_content
    assert_includes response.body, "Please also upload a sample sheet"

    Dir.mktmpdir do |directory|
      directory = Pathname.new(directory)
      FileUtils.cp(EXAMPLES.join("counts.tsv"), directory.join("counts.xlsx"))
      post rnaseq_upload_path, params: { counts_file: upload_file("counts.xlsx", directory), metadata_file: upload_file("sample_metadata.tsv") }
    end
    assert_response :unprocessable_content
    assert_includes response.body, "must be a .tsv, .txt or .csv file"
  end

  test "invalid comparisons are explained and nothing is saved" do
    start
    upload_examples
    base = { condition_column: "condition", reference_level: "control", test_level: "treated",
             alpha: "0.05", lfc_threshold: "0", lfc_test: "posthoc", samples_in_model: "all" }
    {
      { test_level: "control" } => "must be different",
      { test_level: "mutant" } => "Please choose a reference condition and a test condition",
      { condition_column: "sample" } => "column that holds the conditions",
      { alpha: "1.5" } => "between 0 and 1",
      { alpha: "abc" } => "between 0 and 1",
      { lfc_threshold: "-1" } => "0 or more",
      { lfc_test: "maybe" } => "how to apply the fold-change cutoff",
      { covariates: ["condition"] } => "not the condition or time column"
    }.each do |change, message|
      post rnaseq_configure_path, params: base.merge(change)
      assert_response :unprocessable_content, change.inspect
      assert_includes response.body, message, change.inspect
      assert_nil session[:rnaseq_config], change.inspect
    end

    get rnaseq_review_path
    assert_redirected_to rnaseq_configure_path
  end

  test "a condition with a single replicate is rejected" do
    start
    Dir.mktmpdir do |directory|
      directory = Pathname.new(directory)
      metadata = EXAMPLES.join("sample_metadata.tsv").read.sub("control_4\tcontrol", "control_4\tlonely")
      File.write(directory.join("samples.tsv"), metadata)
      post rnaseq_upload_path, params: { counts_file: upload_file("counts.tsv"), metadata_file: upload_file("samples.tsv", directory) }
    end
    assert_redirected_to rnaseq_configure_path
    post rnaseq_configure_path, params: { condition_column: "condition", reference_level: "lonely", test_level: "treated",
                                          alpha: "0.05", lfc_threshold: "0", lfc_test: "posthoc", samples_in_model: "all" }
    assert_response :unprocessable_content
    assert_includes response.body, "&quot;lonely&quot; has 1"
  end

  test "later steps need uploads, and RNA-seq pages need an RNA-seq start" do
    start
    get rnaseq_configure_path
    assert_redirected_to rnaseq_upload_path
    post rnaseq_submit_path
    assert_redirected_to rnaseq_configure_path

    post "/", params: { email: @email }
    assert_redirected_to upload_path
    get rnaseq_upload_path
    assert_redirected_to root_path
  end

  test "changing the files clears the chosen comparison" do
    start
    upload_examples
    post rnaseq_configure_path, params: { condition_column: "condition", reference_level: "control", test_level: "treated",
                                          alpha: "0.05", lfc_threshold: "0", lfc_test: "posthoc", samples_in_model: "all" }
    assert session[:rnaseq_config]
    upload_examples
    assert_nil session[:rnaseq_config]
  end

  test "example annotation tables can be downloaded" do
    %w[annotations.tsv timecourse_annotations.tsv].each do |name|
      get rnaseq_example_path(name)
      assert_response :success
      assert response.body.start_with?("gene_id\tsource\tterm\tdescription"), name
    end
  end

  test "example files can be downloaded and other names cannot" do
    get rnaseq_example_path("counts.tsv")
    assert_response :success
    assert_equal EXAMPLES.join("counts.tsv").read, response.body

    get "/rnaseq/example/..%2Fconfig%2Fdatabase.yml"
    assert_response :not_found
  end

  def upload_time_course
    post rnaseq_upload_path, params: { counts_file: upload_file("timecourse_counts.tsv"),
                                       metadata_file: upload_file("timecourse_sample_metadata.tsv") }
    assert_redirected_to rnaseq_configure_path
  end

  TIME_DEFAULTS = { alpha: "0.05", lfc_threshold: "0", lfc_test: "posthoc", samples_in_model: "all" }.freeze

  test "a condition-by-time analysis is configured, reviewed and queued" do
    start
    upload_time_course
    get rnaseq_configure_path
    assert_select "input[name=experiment_type][value=condition_by_time]"
    assert_select "select#time_column option[selected]", "time"

    post rnaseq_configure_path, params: TIME_DEFAULTS.merge(
      experiment_type: "condition_by_time", condition_column: "condition", time_column: "time",
      reference_level: "control", test_level: "treated"
    )
    assert_redirected_to rnaseq_review_path
    follow_redirect!
    assert_includes response.body, "change differently over time in treated than in control"
    assert_includes response.body, "control at time 0: 3"
    assert_includes response.body, "treated at time 24: 3"
    assert_includes response.body, "group means over time"

    token = session[:upload_token]
    assert_difference "Job.count", 1 do
      post rnaseq_submit_path
    end
    job = Job.find_by!(upload_token: token)
    assert_equal({ "experiment_type" => "condition_by_time", "condition_column" => "condition", "time_column" => "time",
                   "reference_level" => "control", "test_level" => "treated" }, job.analysis_config["deseq2"])
  end

  test "a time course can use one condition or all samples" do
    start
    upload_time_course
    post rnaseq_configure_path, params: TIME_DEFAULTS.merge(
      experiment_type: "time_course", condition_column: "condition", time_column: "time", subset_level: "control",
      reference_level: "control", test_level: "control", lfc_test: "deseq2"
    )
    assert_redirected_to rnaseq_review_path
    assert_equal({ "experiment_type" => "time_course", "condition_column" => "condition", "time_column" => "time", "subset_level" => "control" },
                 session[:rnaseq_config]["deseq2"])
    follow_redirect!
    assert_includes response.body, "change over time in samples with condition = control"
    assert_includes response.body, "time 6: 3"

    post rnaseq_configure_path, params: TIME_DEFAULTS.merge(experiment_type: "time_course", time_column: "time", subset_level: "")
    assert_redirected_to rnaseq_review_path
    assert_equal({ "experiment_type" => "time_course", "time_column" => "time" }, session[:rnaseq_config]["deseq2"])
  end

  test "the number of gene clusters is automatic unless chosen under advanced settings" do
    start
    upload_time_course
    get rnaseq_configure_path
    assert_select "select#clusters option[selected]", "Automatic (recommended)"

    base = TIME_DEFAULTS.merge(experiment_type: "time_course", time_column: "time")
    post rnaseq_configure_path, params: base.merge(clusters: "")
    assert_redirected_to rnaseq_review_path
    assert_not session[:rnaseq_config].key?("clustering")
    follow_redirect!
    assert_includes response.body, "Number chosen automatically from the data"

    %w[1 11 four].each do |clusters|
      post rnaseq_configure_path, params: base.merge(clusters: clusters)
      assert_response :unprocessable_content, clusters
      assert_includes response.body, "whole number from 2 to 10", clusters
    end

    post rnaseq_configure_path, params: base.merge(clusters: "5")
    assert_redirected_to rnaseq_review_path
    assert_equal({ "clusters" => 5 }, session[:rnaseq_config]["clustering"])
    follow_redirect!
    assert_includes response.body, "5 (set by you)"
    get rnaseq_configure_path
    assert_select "select#clusters option[selected]", "5"
    assert_select "details.rnaseq-advanced[open]", false, "clustering is not an advanced setting"

    token = session[:upload_token]
    post rnaseq_submit_path
    assert_equal({ "clusters" => 5 }, Job.find_by!(upload_token: token).analysis_config["clustering"])
  end

  test "the silhouette baseline is off unless ticked under advanced settings" do
    start
    upload_time_course
    get rnaseq_configure_path
    assert_select "input#silhouette_baseline[type=checkbox]:not([checked])"

    base = TIME_DEFAULTS.merge(experiment_type: "time_course", time_column: "time")
    post rnaseq_configure_path, params: base.merge(silhouette_baseline: "1")
    assert_redirected_to rnaseq_review_path
    assert_equal({ "silhouette_baseline" => true }, session[:rnaseq_config]["clustering"])
    follow_redirect!
    assert_includes response.body, "silhouette checked against a shuffled baseline"
    get rnaseq_configure_path
    assert_select "input#silhouette_baseline[checked]"

    post rnaseq_configure_path, params: base.merge(clusters: "4", silhouette_baseline: "1")
    assert_equal({ "clusters" => 4, "silhouette_baseline" => true }, session[:rnaseq_config]["clustering"])
    post rnaseq_configure_path, params: base
    assert_not session[:rnaseq_config].key?("clustering")

    post rnaseq_configure_path, params: TIME_DEFAULTS.merge(condition_column: "condition", reference_level: "control",
                                                            test_level: "treated", silhouette_baseline: "1")
    assert_not session[:rnaseq_config].key?("clustering"), "two-condition analyses are not clustered"
  end

  test "gene clustering is on by default, outside advanced settings, and can be turned off" do
    start
    upload_time_course
    get rnaseq_configure_path
    assert_select "input#cluster_genes[type=checkbox][checked]"
    assert_select "details.rnaseq-advanced select#clusters", false
    assert_select "details.rnaseq-advanced input#cluster_genes", false

    base = TIME_DEFAULTS.merge(experiment_type: "time_course", time_column: "time")
    post rnaseq_configure_path, params: base.merge(cluster_genes: "0", clusters: "4", silhouette_baseline: "1")
    assert_redirected_to rnaseq_review_path
    assert_equal({ "cluster_genes" => false }, session[:rnaseq_config]["clustering"], "the other clustering choices are dropped")
    follow_redirect!
    assert_includes response.body, "Not clustered (turned off)"
    assert_not_includes response.body, "Gaussian process curve for each cluster"
    get rnaseq_configure_path
    assert_select "input#cluster_genes[checked]", false

    post rnaseq_configure_path, params: base.merge(cluster_genes: "1")
    assert_not session[:rnaseq_config].key?("clustering")
  end

  test "a two-condition analysis ignores a number of gene clusters" do
    start
    upload_examples
    post rnaseq_configure_path, params: TIME_DEFAULTS.merge(condition_column: "condition", reference_level: "control",
                                                            test_level: "treated", clusters: "4")
    assert_redirected_to rnaseq_review_path
    assert_not session[:rnaseq_config].key?("clustering")
    follow_redirect!
    assert_not_includes response.body, "Gene clusters"
  end

  test "an optional annotation table is uploaded, reviewed, kept with the comparison, removed and submitted" do
    start
    upload_examples
    post rnaseq_configure_path, params: TIME_DEFAULTS.merge(condition_column: "condition", reference_level: "control", test_level: "treated")
    follow_redirect!
    assert_includes response.body, "not run (no annotation table uploaded)"

    # Adding annotations keeps the chosen comparison.
    post rnaseq_upload_path, params: { annotations_file: upload_file("annotations.tsv") }
    assert_redirected_to rnaseq_configure_path
    assert_equal "annotations.tsv", session[:rnaseq_config]["annotation_file"]
    get rnaseq_review_path
    assert_response :success
    assert_includes response.body, "genes annotated; COG, KEGG"
    assert_includes response.body, "functional enrichment results"
    assert_includes response.body, "group of significant genes (higher and lower)"
    get rnaseq_upload_path
    assert_includes response.body, "Current file: <strong>annotations.tsv</strong>"

    # A bad annotation table is rejected and the good one is kept.
    Dir.mktmpdir do |directory|
      directory = Pathname.new(directory)
      File.write(directory.join("bad.tsv"), "gene\tpathway\ng1\tA\n")
      post rnaseq_upload_path, params: { annotations_file: upload_file("bad.tsv", directory) }
    end
    assert_response :unprocessable_content
    assert_includes response.body, ERB::Util.html_escape("needs columns named \"gene_id\" and \"term\"")
    assert workspace.rnaseq_input_dir.join("annotations.tsv").file?

    post rnaseq_upload_path, params: { remove_annotations: "1" }
    assert_redirected_to rnaseq_configure_path
    assert_not workspace.rnaseq_input_dir.join("annotations.tsv").exist?
    assert_not session[:rnaseq_config].key?("annotation_file")

    post rnaseq_upload_path, params: { annotations_file: upload_file("annotations.tsv") }
    token = session[:upload_token]
    post rnaseq_submit_path
    job = Job.find_by!(upload_token: token)
    assert_equal "annotations.tsv", job.analysis_config["annotation_file"]
    assert job.rnaseq_input_dir.join("annotations.tsv").file?
    assert_equal ["annotations.tsv"], job.submission_options["Uploaded Files"]["Gene Annotations"]
  end

  test "time-course settings that cannot be analyzed are explained" do
    start
    upload_time_course
    base = TIME_DEFAULTS.merge(experiment_type: "condition_by_time", condition_column: "condition", time_column: "time",
                               reference_level: "control", test_level: "treated")
    {
      { time_column: "condition" } => "time column must be different from the condition column",
      { lfc_threshold: "1", lfc_test: "deseq2" } => "can only be applied after testing",
      { covariates: ["time"] } => "not the condition or time column",
      { experiment_type: "unknown" } => "Please choose a type of analysis"
    }.each do |change, message|
      post rnaseq_configure_path, params: base.merge(change)
      assert_response :unprocessable_content, change.inspect
      assert_includes response.body, ERB::Util.html_escape(message), change.inspect
    end

    # A time point with a single replicate in one condition and none in the other.
    Dir.mktmpdir do |directory|
      directory = Pathname.new(directory)
      sheet = EXAMPLES.join("timecourse_sample_metadata.tsv").read.sub("treated_t24_3\ttreated\t24", "treated_t24_3\ttreated\t48")
      File.write(directory.join("samples.tsv"), sheet)
      post rnaseq_upload_path, params: { metadata_file: upload_file("samples.tsv", directory) }
    end
    assert_redirected_to rnaseq_configure_path
    post rnaseq_configure_path, params: base
    assert_response :unprocessable_content
    assert_includes response.body, "control at time 48 (0), treated at time 48 (1)"
  end
end
