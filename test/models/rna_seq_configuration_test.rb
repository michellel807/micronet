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
end
