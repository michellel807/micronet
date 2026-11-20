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

  test "a time course can turn gene clustering off" do
    time = { experiment_type: "time_course", time_column: "time" }
    assert configuration(deseq2: time).cluster_genes?
    assert_not configuration.cluster_genes?, "two-condition analyses are never clustered"

    off = RnaSeq::Configuration.from_h(configuration(deseq2: time, clustering: { cluster_genes: false }).to_h.as_json)
    assert_not off.cluster_genes?
    assert_equal "Not clustered (turned off)", off.summary["Gene clusters"]
    [{ cluster_genes: true }, { cluster_genes: false, clusters: 4 }, { cluster_genes: false, silhouette_baseline: true }].each do |clustering|
      assert_raises(RnaSeq::Configuration::Invalid, clustering.inspect) { configuration(deseq2: time, clustering: clustering) }
    end
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(clustering: { cluster_genes: false }) }
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

  GP = { experiment_type: "condition_time_gp", reference_level: "control", test_level: "treated", time_column: "time",
         sampling_design: "independent" }.freeze

  test "the Gaussian process comparison is a time course whose clusters are always tested" do
    gp = configuration(deseq2: GP)
    assert gp.time_course?
    assert gp.gp_test?
    assert gp.cluster_genes?
    assert_nil gp.treatment_start
    assert_equal 999, gp.permutations
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: GP, clustering: { cluster_genes: false }) }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: GP.except(:test_level)) }
  end

  test "how the samples were collected must be stated and is never assumed" do
    error = assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: GP.except(:sampling_design)) }
    assert_includes error.message, "how the samples were collected"
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: GP.merge(sampling_design: "pooled")) }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: GP.merge(sampling_design: "repeated")) }
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(deseq2: GP.merge(replicate_column: "culture")) }
    assert_raises(RnaSeq::Configuration::Invalid) do
      configuration(deseq2: { reference_level: "control", test_level: "treated", sampling_design: "independent" })
    end

    repeated = configuration(deseq2: GP.merge(sampling_design: "repeated", replicate_column: "culture"))
    assert_equal "Each culture was sampled at several time points (cultures in column culture)", repeated.summary["Sampling"]
    assert_equal "Each sample is a separate culture, harvested once", configuration(deseq2: GP).summary["Sampling"]
  end

  test "the treatment time, gene selection and permutations are kept apart from the DESeq2 settings" do
    chosen = configuration(deseq2: GP, gp_test: { treatment_start: 6.0, variable_percent: 20, permutations: 199 })
    loaded = RnaSeq::Configuration.from_h(chosen.to_h.as_json)
    assert_equal 6.0, loaded.treatment_start
    assert_equal 20, loaded.variable_percent
    assert_equal 199, loaded.permutations
    assert_not loaded.deseq2.key?("treatment_start"), "the R script rejects settings it does not know"
    assert_not configuration(deseq2: GP).to_h.key?("gp_test")

    [{ treatment_start: "6" }, { variable_percent: 0 }, { variable_percent: 101 }, { permutations: 10 },
     { permutations: 999.5 }, { seed: 1 }].each do |settings|
      assert_raises(RnaSeq::Configuration::Invalid, settings.inspect) { configuration(deseq2: GP, gp_test: settings) }
    end
    assert_raises(RnaSeq::Configuration::Invalid) { configuration(gp_test: { permutations: 199 }) }
  end

  test "the summary of a Gaussian process comparison describes its test" do
    summary = configuration(deseq2: GP, gp_test: { treatment_start: 6.0 }).summary
    assert_equal "RNA-seq: Compare conditions over time (Gaussian process test) (normalized with DESeq2; B-GREAT-style test of each gene cluster)",
                 summary["Analysis"]
    assert_equal "Added at time 6; samples up to then are a shared baseline", summary["Treatment"]
    assert_equal "cluster q-value < 0.05 (999 label permutations)", summary["Significance"]
    assert_equal "The 1000 most variable genes (or half of the genes, if that is fewer)", summary["Genes clustered"]
    assert_includes summary["Comparison"], "treated than in control (reference)"
    assert_equal "Before the first sample (treated from the start)", configuration(deseq2: GP).summary["Treatment"]
    assert_equal "The top 12.5% most variable genes",
                 configuration(deseq2: GP, gp_test: { variable_percent: 12.5 }).summary["Genes clustered"]
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
