require 'minitest/autorun'
require_relative '../../app/models/DataFile' # Adjust path as needed
require 'tempfile'
require "test_helper"

class DataFileTest < ActiveSupport::TestCase
  def setup
    # Create a dummy valid mapping file with plate_id "2020-06-22-R1"
    @mapping_file = Tempfile.new(['mapping', '.txt'])
    @mapping_file.write("Well\tPlate_ID\tSubstrate\tConcentration\tIsolate\tRibotype\tGroup\tControl\nA1\t2020-06-22-R1\tGlucose\tLow\tCD1007\tRT053\t1\t0")
    @mapping_file.rewind
  end

  def teardown
    @mapping_file.close
    @mapping_file.unlink
  end

  def fake_uploaded_file(filename, content = "header\tvalue\nrow1\tdata\n")
    tempfile = Tempfile.new
    tempfile.write(content)
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(
      filename: filename,
      tempfile: tempfile,
      type: "text/plain"
    )
  end

  test "rejects invalid extension" do
    file = fake_uploaded_file('invalid.exe')
    data_file = DataFile.new(file, @mapping_file.path)
    refute data_file.valid?
    assert_match(/Invalid data file format/, data_file.error_message)
  end

  test "accepts and converts csv to txt" do
    csv_content = "Col1,Col2\nA,B\nC,D\n"
    file = fake_uploaded_file('data.csv', csv_content)
    data_file = DataFile.new(file, @mapping_file.path)

    assert data_file.valid?
    assert_match(/\.txt\z/, data_file.file_path)
    content = File.read(data_file.file_path)
    # Expect tab-separated values in saved file
    assert_includes content, "Col1\tCol2"
    assert_includes content, "A\tB"
  end

  test "accepts txt, tsv, asc and saves as txt with header replaced" do
    %w[data.txt data.tsv data.asc].each do |filename|
      file = fake_uploaded_file(filename, "Col1\tCol2\n1\t2\n3\t4\n")
      data_file = DataFile.new(file, @mapping_file.path)

      assert data_file.valid?, "File #{filename} should be valid"
      assert_match(/\.txt\z/, data_file.file_path)
      content = File.read(data_file.file_path)
      assert_includes content, "Well positions\tCol2" # Header replaced to "Well positions"
      assert_includes content, "1\t2"
    end
  end

  test "data file is named using mapping file plate_id" do
    # Mapping file plate_id is "2020-06-22-R1" from setup
    file = fake_uploaded_file('data.csv', "Col1,Col2\nA,B\n")
    data_file = DataFile.new(file, @mapping_file.path)

    assert data_file.valid?
    # File saved with name matching mapping file's basename (which is @mapping_file.path)
    expected_name = File.basename(@mapping_file.path, '.*') + '.txt'
    assert_match(/#{Regexp.escape(expected_name)}\z/, data_file.file_path)
  end
end
