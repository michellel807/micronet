require "test_helper"

class ReviewHeatmapValidationTest < ActionController::TestCase
  tests ReviewController

  setup do
    user = User.create!(email: "review-heatmap-validation@example.com")
    @job = Job.create!(user: user, status: Job::DRAFT_STATUS)
    session[:current_user_id] = @job.id
  end

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
    @job.ensure_upload_directories!
    mapping_path = @job.mapping_dir.join("mapping.txt")
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
    user = User.create!(email: "generate-heatmap-validation@example.com")
    @job = Job.create!(user: user, status: Job::DRAFT_STATUS)
    session[:current_user_id] = @job.id
    session[:chart_types] = ["heatmap_plot"]
    session[:heatmap_value] = "Growth Rate"
    session[:heatmap_x] = "Condition"
    session[:mapping_file_paths] = []
  end

  test "submission endpoint does not queue a heatmap with incomplete selections" do
    post :run

    assert_redirected_to selectanalyses_path
    assert_equal "Please select a heatmap value and two different axes before continuing.", flash[:error]
    assert_equal Job::DRAFT_STATUS, @job.reload.status
  end
end
