require "test_helper"

class RnaSeqInputsTest < ActiveSupport::TestCase
  COUNTS = "gene_id\ta1\ta2\tb1\tb2\tb3\ng1\t10\t0\t5\t7\t3\ng2\t1\t2\t3\t4\t5\n".freeze
  METADATA = "sample\tcondition\tbatch\na1\tctrl\tx\na2\tctrl\ty\nb1\ttrt\tx\nb2\ttrt\ty\nb3\ttrt\tx\n".freeze

  setup { @directory = Pathname.new(Dir.mktmpdir) }
  teardown { FileUtils.rm_rf(@directory) }

  def inputs(counts: COUNTS, metadata: METADATA, counts_name: "counts.tsv", metadata_name: "metadata.tsv")
    counts_path = @directory.join(counts_name)
    metadata_path = @directory.join(metadata_name)
    File.write(counts_path, counts)
    File.write(metadata_path, metadata)
    RnaSeq::Inputs.new(counts_path, metadata_path)
  end

  def assert_invalid(pattern, **files)
    error = assert_raises(RnaSeq::Inputs::Invalid) { inputs(**files) }
    assert_match pattern, error.message
  end

  test "reads samples, condition columns and replicate counts" do
    result = inputs
    assert_equal %w[a1 a2 b1 b2 b3], result.sample_ids
    assert_equal %w[condition batch], result.condition_columns
    assert_equal({ "ctrl" => 2, "trt" => 3 }, result.levels("condition"))
    assert_equal({ "x" => 3, "y" => 2 }, result.levels("batch"))
    assert_equal({}, result.levels("sample"))
  end

  test "the example files are accepted" do
    examples = Rails.root.join("lib/examplefiles/rnaseq")
    result = RnaSeq::Inputs.new(examples.join("counts.tsv"), examples.join("sample_metadata.tsv"))
    assert_equal({ "control" => 4, "treated" => 4 }, result.levels("condition"))
  end

  test "csv files, quoted fields and R-style headers without a gene column are accepted" do
    counts = "\"a1\",\"a2\",\"b1\",\"b2\"\n\"g1\",1,2,3,4\n"
    metadata = "sample,condition\na1,ctrl\na2,ctrl\nb1,trt\nb2,trt\n"
    result = inputs(counts: counts, metadata: metadata, counts_name: "counts.csv", metadata_name: "metadata.csv")
    assert_equal %w[a1 a2 b1 b2], result.sample_ids
  end

  test "sample names must match between the files" do
    metadata = METADATA.sub("b3\ttrt\tx\n", "c9\ttrt\tx\n")
    assert_invalid(/count matrix but not the sample sheet: "b3".*sample sheet but not the count matrix: "c9"/, metadata: metadata)
  end

  test "counts must be raw whole numbers" do
    assert_invalid(/raw, non-negative whole-number counts.*"2.5"/, counts: COUNTS.sub("\t2\t", "\t2.5\t"))
    assert_invalid(/"-1"/, counts: COUNTS.sub("\t0\t", "\t-1\t"))
  end

  test "rows must have as many columns as the header" do
    assert_invalid(/Row 3 of the count matrix has 5 columns/, counts: COUNTS.sub("\t5\n", "\n"))
  end

  test "the sample sheet needs a sample column and a condition column" do
    assert_invalid(/column named "sample"/, metadata: METADATA.sub("sample\t", "name\t"))
    assert_invalid(/at least one column besides "sample"/, metadata: "sample\na1\na2\nb1\nb2\nb3\n")
  end

  test "duplicates, blanks and too few samples are rejected" do
    assert_invalid(/duplicate sample columns: "a1"/, counts: COUNTS.sub("\ta2\t", "\ta1\t"))
    assert_invalid(/more than once: "a1"/, metadata: METADATA.sub("a2\tctrl", "a1\tctrl"))
    assert_invalid(/empty value for sample "a2"/, metadata: METADATA.sub("a2\tctrl\ty", "a2\t\ty"))
    assert_invalid(/at least 4 sample columns/, counts: "gene_id\ta1\ta2\ng1\t1\t2\n")
  end

  test "empty and missing files are reported" do
    assert_invalid(/count matrix is empty/, counts: "")
    assert_invalid(/header row but no genes/, counts: "gene_id\ta1\ta2\tb1\tb2\n")
    error = assert_raises(RnaSeq::Inputs::Invalid) { RnaSeq::Inputs.new(@directory.join("none.tsv"), @directory.join("none2.tsv")) }
    assert_match(/upload a count matrix/, error.message)
  end
end
