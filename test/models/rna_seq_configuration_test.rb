require "test_helper"

class RnaSeqConfigurationTest < ActiveSupport::TestCase
  def configuration(**overrides)
    RnaSeq::Configuration.new(
      counts_file: "counts.csv", metadata_file: "samples.tsv",
      original_filenames: { counts: "My Counts.csv", metadata: "samples.tsv" },
      deseq2: { reference_level: "control", test_level: "treated" }, **overrides
    )
  end

  test "settings survive saving to and loading from the job" do
    original = configuration(deseq2: { reference_level: "wt", test_level: "ko", covariates: ["batch"], alpha: 0.1 })
    restored = RnaSeq::Configuration.from_h(JSON.parse(original.to_h.to_json))

    assert_equal original.to_h, restored.to_h
    assert_equal ["batch"], restored.deseq2["covariates"]
  end

  test "the DESeq2 settings are written unchanged for the R script" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "config.json")
      configuration(deseq2: { reference_level: "control", test_level: "treated", lfc_threshold: 1 }).write_deseq2_config(path)
      assert_equal({ "reference_level" => "control", "test_level" => "treated", "lfc_threshold" => 1 }, JSON.parse(File.read(path)))
    end
  end

  test "the summary describes the comparison, settings and original file names" do
    summary = configuration(deseq2: { reference_level: "control", test_level: "treated", covariates: ["batch"], lfc_threshold: 1 }).summary

    assert_equal "RNA-seq: Two-condition differential expression (DESeq2)", summary["Analysis"]
    assert_equal "treated vs control (reference), column condition", summary["Comparison"]
    assert_equal "batch", summary["Covariates"]
    assert_equal "adjusted p-value < 0.05 and |log2 fold change| ≥ 1", summary["Significance"]
    assert_equal ["My Counts.csv"], summary["Uploaded Files"]["Count Matrix"]
    assert_not summary.key?("Analyses To Run"), "the growth-only email section must not be used"
  end

  test "unknown settings, paths and missing levels are rejected" do
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: { reference_level: "a", test_level: "b", alhpa: 0.1 }) }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: { reference_level: "a" }) }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(counts_file: "../counts.csv") }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(counts_file: "counts.xlsx") }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(metadata_file: "counts.csv") }
  end

  test "inputs must be regular files in the RNA-seq input folder" do
    workspace = UploadWorkspace.create!
    FileUtils.mkdir_p(workspace.rnaseq_input_dir)
    workspace.rnaseq_input_dir.join("counts.csv").write("gene_id,a\n")
    assert_not configuration.inputs_present?(workspace)

    File.symlink(workspace.rnaseq_input_dir.join("counts.csv"), workspace.rnaseq_input_dir.join("samples.tsv"))
    assert_not configuration.inputs_present?(workspace)

    File.delete(workspace.rnaseq_input_dir.join("samples.tsv"))
    workspace.rnaseq_input_dir.join("samples.tsv").write("sample\tcondition\n")
    assert configuration.inputs_present?(workspace)
  ensure
    workspace&.clear_uploads!
  end

  test "time courses need a time column but no reference unless conditions are compared" do
    time_course = configuration(deseq2: { experiment_type: "time_course", time_column: "hours", condition_column: "strain", subset_level: "wt" })
    assert time_course.time_course?
    assert_equal "Change over time (column hours), samples with strain = wt", time_course.summary["Comparison"]

    interaction = configuration(deseq2: { experiment_type: "condition_by_time", reference_level: "wt", test_level: "ko", time_column: "hours" })
    assert_equal "How ko vs wt (reference) changes over time (columns condition and hours)", interaction.summary["Comparison"]
    assert_equal "RNA-seq: Condition-by-time interaction (DESeq2)", interaction.summary["Analysis"]

    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: { experiment_type: "condition_by_time", time_column: "hours" }) }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: { experiment_type: "multi_condition", reference_level: "a", test_level: "b" }) }
    assert_not configuration.time_course?
  end

  test "a time course keeps an optional number of gene clusters apart from the DESeq2 settings" do
    time = { experiment_type: "time_course", time_column: "time" }
    automatic = configuration(deseq2: time)
    assert_nil automatic.cluster_count
    assert_not automatic.to_h.key?("clustering")
    assert_equal "Number chosen automatically from the data", automatic.summary["Gene clusters"]

    chosen = configuration(deseq2: time, clustering: { clusters: 4 })
    loaded = RnaSeq::Configuration.from_h(chosen.to_h.as_json)
    assert_equal 4, loaded.cluster_count
    assert_equal "4 (set by you)", loaded.summary["Gene clusters"]
    assert_not loaded.deseq2.key?("clusters"), "the R script rejects settings it does not know"

    assert_not configuration.summary.key?("Gene clusters")
    [{ clusters: 1 }, { clusters: 11 }, { clusters: "4" }, { k: 4 }].each do |clustering|
      assert_raises(RnaSeq::Configuration::Invalid, clustering.inspect) { configuration(deseq2: time, clustering: clustering) }
    end
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(clustering: { clusters: 4 }) }
  end

  test "a time course can ask for a shuffled silhouette baseline" do
    time = { experiment_type: "time_course", time_column: "time" }
    assert_not configuration(deseq2: time).silhouette_baseline?

    checked = RnaSeq::Configuration.from_h(configuration(deseq2: time, clustering: { silhouette_baseline: true }).to_h.as_json)
    assert checked.silhouette_baseline?
    assert_nil checked.cluster_count
    assert_equal "Number chosen automatically from the data; silhouette checked against a shuffled baseline",
                 checked.summary["Gene clusters"]
    both = configuration(deseq2: time, clustering: { clusters: 4, silhouette_baseline: true })
    assert_equal "4 (set by you); silhouette checked against a shuffled baseline", both.summary["Gene clusters"]

    [false, "true", 1].each do |value|
      assert_raises(RnaSeq::Configuration::Invalid, value.inspect) { configuration(deseq2: time, clustering: { silhouette_baseline: value }) }
    end
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(clustering: { silhouette_baseline: true }) }
  end

  test "an optional annotation table is saved and summarized" do
    without = configuration
    assert_nil without.annotation_file
    assert_not without.to_h.key?("annotation_file")
    assert_equal "Not run (no annotation table uploaded)", without.summary["Functional enrichment"]
    assert_not without.summary["Uploaded Files"].key?("Gene Annotations")

    with = configuration(annotation_file: "annotations.tsv",
                         original_filenames: { counts: "c.csv", metadata: "m.tsv", annotations: "KEGG genes.tsv" })
    loaded = RnaSeq::Configuration.from_h(with.to_h.as_json)
    assert_equal "annotations.tsv", loaded.annotation_file
    assert_equal ["KEGG genes.tsv"], loaded.summary["Uploaded Files"]["Gene Annotations"]
    assert_equal "Fisher's exact test against KEGG genes.tsv", loaded.summary["Functional enrichment"]
    assert_equal %w[counts.csv samples.tsv annotations.tsv], loaded.input_files

    assert_raises(RnaSeq::Configuration::Invalid) { configuration(annotation_file: "../annotations.tsv") }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(annotation_file: "annotations.xlsx") }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(annotation_file: "counts.csv") }
  end
end
