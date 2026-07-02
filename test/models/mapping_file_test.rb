require 'minitest/autorun'
require_relative '../../app/models/MappingFile' # Adjust path as needed
require 'tempfile'
require "securerandom"
require "fileutils"
require "test_helper"

class MappingFileTest < ActiveSupport::TestCase
  def setup
    @upload_root = Rails.root.join("tmp", "test_uploads", SecureRandom.hex(8))
    FileUtils.mkdir_p(@upload_root.join("mapping"))
  end

  def teardown
    FileUtils.rm_rf(@upload_root)
  end

  def fake_uploaded_file(filename, content = "Well positions\tPlate_ID\nSample1\tValue1\n")
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
    mapping_file = MappingFile.new(file, upload_root: @upload_root)
    refute mapping_file.valid?
    assert_match(/Invalid mapping file format/, mapping_file.error_message)
  end

  test "accepts and converts csv to txt and names by plate_id" do
    csv_content = "Well,Plate_ID,Substrate,Concentration,Isolate,Ribotype,Group,Control\nA1,2020-06-22-R1,Glucose,Low,CD1007,RT053,1,0"
    file = fake_uploaded_file('map.csv', csv_content)
    mapping_file = MappingFile.new(file, upload_root: @upload_root)

    assert mapping_file.valid?
    assert_match(/\.txt\z/, mapping_file.file_path)

    expected_name = '2020-06-22-R1.txt'
    assert_includes mapping_file.file_path, expected_name

    content = File.read(mapping_file.file_path)
    assert_includes content, "Well\tPlate_ID"
  end

  test "accepts and processes txt, tsv, asc" do
    %w[mapping.txt mapping.tsv mapping.asc].each do |filename|
      content = "Well\tPlate_ID\tSubstrate\tConcentration\tIsolate\tRibotype\tGroup\tControl\nA1\t2020-06-22-R1\tGlucose\tLow\tCD1007\tRT053\t1\t0"
      file = fake_uploaded_file(filename, content)
      mapping_file = MappingFile.new(file, upload_root: @upload_root)

      assert mapping_file.valid?, "File #{filename} should be valid"
      expected_name = '2020-06-22-R1.txt'
      assert_includes mapping_file.file_path, expected_name
      content = File.read(mapping_file.file_path)
      assert_includes content, "Well\tPlate_ID"
    end
  end
end
