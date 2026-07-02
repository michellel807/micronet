require 'minitest/autorun'
require_relative '../../app/models/MetaFile' # Adjust path
require 'tempfile'
require "securerandom"
require "fileutils"
require "test_helper"

class MetaFileTest < ActiveSupport::TestCase
    def setup
        @upload_root = Rails.root.join("tmp", "test_uploads", SecureRandom.hex(8))
        FileUtils.mkdir_p(@upload_root.join("mapping"))
    end

    def teardown
        FileUtils.rm_rf(@upload_root)
    end

    def fake_uploaded_file(filename, content = "Plate_ID,Other_Info\nP001,Data1\nP002,Data2\n")
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
        meta_file = MetaFile.new(file, upload_root: @upload_root)
        refute meta_file.valid?
        assert_match(/Invalid meta file format/, meta_file.error_message)
    end

    test "accepts and converts csv to txt and extracts plate_ids" do
        csv_content = "Plate_ID,Isolate,Ribotype,PM,Replicate\n2020-06-22-R1,CD2015,RT027,1,1\n2020-06-22-R2,CD2015,RT027,1,2"
        file = fake_uploaded_file('metafile1.csv', csv_content)
        meta_file = MetaFile.new(file, upload_root: @upload_root)

        assert meta_file.valid?
        assert_equal 'meta.txt', File.basename(meta_file.file_path)

        output = File.read(meta_file.file_path)
        assert_includes output, "2020-06-22-R1\tCD2015\tRT027\t1\t1"
        assert_includes output, "2020-06-22-R2\tCD2015\tRT027\t1\t2"
        assert_equal ['2020-06-22-R1', '2020-06-22-R2'], meta_file.plate_id_values.sort
    end

    test "accepts txt, tsv, asc and extracts plate_ids" do
    %w[metafile2.txt meta.tsv meta.asc].each do |filename|
        content = "Plate_ID\tIsolate\tRibotype\tPM\tReplicate\n2020-06-22-R1\tCD2015\tRT027\t1\t1\n2020-06-22-R2\tCD2015\tRT027\t1\t2"
        file = fake_uploaded_file(filename, content)
        meta_file = MetaFile.new(file, upload_root: @upload_root)

        assert meta_file.valid?, "File #{filename} should be valid"
        assert_equal ['2020-06-22-R1', '2020-06-22-R2'], meta_file.plate_id_values.sort
        assert_equal 'meta.txt', File.basename(meta_file.file_path)

        saved_content = File.read(meta_file.file_path)
        assert_includes saved_content, "2020-06-22-R1\tCD2015\tRT027\t1\t1"
        assert_includes saved_content, "2020-06-22-R2\tCD2015\tRT027\t1\t2"
        end
    end

    test "meta plate IDs match data file names" do
    meta_content = "Plate_ID,Isolate,Ribotype,PM,Replicate\n2020-06-22-R1,CD2015,RT027,1,1\n2020-06-22-R2,CD2015,RT027,1,2"
    file = fake_uploaded_file('metafile3.csv', meta_content)
    meta_file = MetaFile.new(file, upload_root: @upload_root)

    data_file_paths = [
      Rails.root.join('tmp', '2020-06-22-R1.txt').to_s,
      Rails.root.join('tmp', '2020-06-22-R2.txt').to_s
    ]

    assert meta_file.valid?
    assert_equal ['2020-06-22-R1', '2020-06-22-R2'], meta_file.plate_id_values.sort

    data_plate_ids = data_file_paths.map { |path| File.basename(path, '.*') }
    assert_equal meta_file.plate_id_values.sort, data_plate_ids.sort, "Plate IDs in meta file must match data file names"
    end

end
