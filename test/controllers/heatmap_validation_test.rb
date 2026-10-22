require "test_helper"

class ReviewHeatmapValidationTest < ActionController::TestCase
  tests ReviewController

  setup do
    @user = User.create!(email: "review-heatmap-validation@example.com")
    @workspace = UploadWorkspace.create!
    session[:user_id] = @user.id
    session[:upload_token] = @workspace.token
  end

  teardown { @workspace.clear_uploads! }

  test "review rejects a heatmap with a missing axis" do
    session[:data_file_paths] = []
    session[:usr_data_file_paths] = []
    session[:mapping_file_paths] = []
    session[:usr_mapping_file_paths] = []

    post :index, params: {
      chart_types: ["heatmap_plot"],
      heatmap_value: "Growth Rate",
      heatmap_x: "Condition"
    }

    assert_redirected_to selectanalyses_path
    assert_equal "Please select a heatmap value and two different axes before continuing.", flash[:error]
  end

  test "review rejects identical heatmap axes" do
    @workspace.ensure_upload_directories!
    mapping_path = @workspace.mapping_dir.join("mapping.txt")
    File.write(mapping_path, "Well\tCondition\nA1\tControl\n")
    session[:mapping_file_paths] = [mapping_path.to_s]
    session[:data_file_paths] = []
    session[:usr_data_file_paths] = []
    session[:usr_mapping_file_paths] = []

    post :index, params: {
      chart_types: ["heatmap_plot"],
      heatmap_value: "Growth Rate",
      heatmap_x: "Condition",
      heatmap_y: "Condition"
    }

    assert_redirected_to selectanalyses_path
    assert_equal "Please select a heatmap value and two different axes before continuing.", flash[:error]
  end
end

class GenerateHeatmapValidationTest < ActionController::TestCase
  tests GenerateController

  setup do
    @user = User.create!(email: "generate-heatmap-validation@example.com")
    @workspace = UploadWorkspace.create!
    session[:user_id] = @user.id
    session[:upload_token] = @workspace.token
    session[:chart_types] = ["heatmap_plot"]
    session[:heatmap_value] = "Growth Rate"
    session[:heatmap_x] = "Condition"
    session[:mapping_file_paths] = []
  end

  teardown { @workspace.clear_uploads! }

  test "submission endpoint does not queue a heatmap with incomplete selections" do
    post :run

    assert_redirected_to selectanalyses_path
    assert_equal "Please select a heatmap value and two different axes before continuing.", flash[:error]
    assert_equal 0, @user.jobs.count
  end
end
