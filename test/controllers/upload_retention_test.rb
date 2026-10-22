require "test_helper"
require "minitest/mock"

class UploadRetentionTest < ActionController::TestCase
  tests UploadController

  setup do
    user = User.create!(email: "upload-retention@example.com")
    @workspace = UploadWorkspace.create!
    session[:user_id] = user.id
    session[:upload_token] = @workspace.token
    @workspace.ensure_upload_directories!
    @data = @workspace.data_dir.join("file1.txt")
    File.write(@data, "OD\nTime\t#{(0...32).to_a.join("\t")}\nA1\t#{Array.new(32, 1).join("\t")}\n")
    @mapping = @workspace.mapping_dir.join("file1.txt")
    File.write(@mapping, "Well\tPlate_ID\tCondition\nA1\tfile1\tControl\n")
    @interval = @workspace.parameters_dir.join("interval.txt")
    File.write(@interval, "file1\t600\n")
    File.write(@workspace.pair_metadata_path, { pairs: [{ pair_key: "file1", pair_index: 1, original_data_filename: "data.txt", original_mapping_filename: "mapping.txt", parsed_plate_id: "plate1" }] }.to_json)
    session[:data_file_paths] = [@data.to_s]
    session[:mapping_file_paths] = [@mapping.to_s]
    session[:usr_data_file_paths] = ["data.txt"]
    session[:usr_mapping_file_paths] = ["mapping.txt"]
    session[:interval_file_path] = @interval.to_s
    session[:usr_interval_file_path] = "interval.txt"
    session[:gp_time_step_size] = 2
  end

  teardown do
    @workspace.clear_uploads!
  end

  test "revisit includes saved fields and time step without replacement warning" do
    get :index
    assert_response :success
    assert_select "#gp-time-step-size[value='2']"
    assert_includes response.body, '"data_name":"data.txt"'
    assert_includes response.body, '"mapping_name":"mapping.txt"'
    assert_includes response.body, '"interval.txt"'
    assert_not_includes response.body, "Submitting replaces"
  end

  test "submitting saved rows retains files and updates the time step" do
    contents = File.read(@data)
    session[:chart_types] = ["gp_plot"]
    Python.stub(:exec, true) do
      post :upload, params: { retained_pairs: { "1" => "0" }, gp_time_step_size: "3" }
    end
    assert_redirected_to selectanalyses_path
    assert_equal 3, session[:gp_time_step_size]
    assert_equal ["gp_plot"], session[:chart_types]
    assert_equal contents, File.read(session[:data_file_paths].first)
    assert_equal ["mapping.txt"], session[:usr_mapping_file_paths]
    assert_equal "interval.txt", session[:usr_interval_file_path]
  end

  test "replacing only mapping retains data and interval" do
    contents = File.read(@data)
    file = Tempfile.new(["replacement", ".txt"])
    file.write("Well\tPlate_ID\tCondition\nA1\tplate1\tTreatment\n")
    file.close
    upload = Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "replacement.txt")
    Python.stub(:exec, true) do
      post :upload, params: { retained_pairs: { "1" => "0" }, mapping_pair_files: { "1" => upload }, gp_time_step_size: "2" }
    end
    assert_redirected_to selectanalyses_path
    assert_equal contents, File.read(@data)
    assert_includes File.read(@mapping), "Treatment"
    assert_equal ["replacement.txt"], session[:usr_mapping_file_paths]
    assert File.file?(@interval)
    assert File.file?(@workspace.upload_root.join("originals", "mapping", "file1.txt"))
  ensure
    file&.unlink
  end

  test "removing a saved mapping without replacement preserves saved inputs" do
    post :upload, params: {
      retained_pairs: { "1" => "0" }, remove_mapping_pairs: ["1"],
      remove_interval_file: "1", gp_time_step_size: "2"
    }
    assert_redirected_to upload_path
    assert_equal "Each pair must include both a data file and a mapping file.", flash[:alert]
    assert_equal [@mapping.to_s], session[:mapping_file_paths]
    assert_equal @interval.to_s, session[:interval_file_path]
    assert File.exist?(@mapping)
    assert File.exist?(@interval)
    assert File.exist?(@data)
  end

  test "removing the optional interval retains the pair" do
    Python.stub(:exec, true) do
      post :upload, params: { retained_pairs: { "1" => "0" }, remove_interval_file: "1", gp_time_step_size: "2" }
    end
    assert_redirected_to selectanalyses_path
    assert_nil session[:interval_file_path]
    assert_not File.exist?(@interval)
    assert File.exist?(@mapping)
  end

  test "data alone is rejected even with a meta file" do
    file = Tempfile.new(["data-only", ".txt"])
    file.write(File.read(@data))
    file.close
    upload = Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "data_only.txt")
    post :upload, params: { data_pair_files: { "1" => upload }, meta_files: upload, gp_time_step_size: "2" }
    assert_redirected_to upload_path
    assert_equal "Each pair must include both a data file and a mapping file.", flash[:alert]
    assert_equal ["data.txt"], session[:usr_data_file_paths]
  ensure
    file&.unlink
  end

  test "a retained data-only upload cannot bypass the mapping requirement" do
    session[:mapping_file_paths] = []
    session[:usr_mapping_file_paths] = []
    post :upload, params: { retained_pairs: { "1" => "0" }, gp_time_step_size: "2" }
    assert_redirected_to upload_path
    assert_equal "Each pair must include both a data file and a mapping file.", flash[:alert]
  end

  test "removing a pair renumbers the remaining pair without mixing files" do
    second_data = @workspace.data_dir.join("file2.txt")
    File.write(second_data, File.read(@data).sub("A1", "B1"))
    second_mapping = @workspace.mapping_dir.join("file2.txt")
    File.write(second_mapping, File.read(@mapping).sub("A1", "B1"))
    session[:mapping_file_paths] += [second_mapping.to_s]
    session[:usr_mapping_file_paths] += ["second_mapping.txt"]
    metadata = JSON.parse(File.read(@workspace.pair_metadata_path))
    metadata["pairs"] << { "pair_key" => "file2", "pair_index" => 2, "original_mapping_filename" => "second_mapping.txt", "parsed_plate_id" => "plate2" }
    File.write(@workspace.pair_metadata_path, metadata.to_json)
    session[:data_file_paths] += [second_data.to_s]
    session[:usr_data_file_paths] += ["second.txt"]
    Python.stub(:exec, true) do
      post :upload, params: { retained_pairs: { "2" => "1" }, remove_interval_file: "1", gp_time_step_size: "2" }
    end
    assert_redirected_to selectanalyses_path
    assert_equal ["second.txt"], session[:usr_data_file_paths]
    assert_includes File.read(@data), "B1"
    assert_not File.exist?(second_data)
    assert_equal ["second_mapping.txt"], session[:usr_mapping_file_paths]
    assert_includes File.read(@mapping), "B1"
  end

  test "adding a pair carries forward existing pairs and optional files" do
    file = Tempfile.new(["second", ".txt"])
    file.write(File.read(@data))
    file.close
    upload = Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "second.txt")
    Python.stub(:exec, true) do
      post :upload, params: { retained_pairs: { "1" => "0" }, data_pair_files: { "2" => upload }, mapping_pair_files: { "2" => Rack::Test::UploadedFile.new(@mapping.to_s, "text/plain", original_filename: "second_mapping.txt") }, gp_time_step_size: "2" }
    end
    assert_redirected_to selectanalyses_path
    assert_equal ["data.txt", "second.txt"], session[:usr_data_file_paths]
    assert_equal ["mapping.txt", "second_mapping.txt"], session[:usr_mapping_file_paths]
    assert_equal "interval.txt", session[:usr_interval_file_path]
    assert_equal 2, session[:data_file_paths].length
  ensure
    file&.unlink
  end

  test "invalid edits preserve saved files and settings" do
    contents = File.read(@mapping)
    Python.stub(:exec, false) do
      post :upload, params: { retained_pairs: { "1" => "0" }, remove_interval_file: "1", gp_time_step_size: "3" }
    end
    assert_redirected_to upload_path
    assert_equal contents, File.read(@mapping)
    assert_equal 2, session[:gp_time_step_size]
    assert File.exist?(@interval)
  end

  test "invalid time step preserves saved files" do
    Python.stub(:exec, true) do
      post :upload, params: { retained_pairs: { "1" => "0" }, gp_time_step_size: "100" }
    end
    assert_match(/too large/, flash[:alert])
    assert_response :success
    assert_equal 2, session[:gp_time_step_size]
    assert File.exist?(@data)
  end
end
