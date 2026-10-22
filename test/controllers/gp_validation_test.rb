require "test_helper"

class ReviewGpValidationTest < ActionController::TestCase
  tests ReviewController

  setup do
    @user = User.create!(email: "review-gp-validation@example.com")
    @workspace = Job.create!(user: @user, status: Job::DRAFT_STATUS)
    session[:current_user_id] = @workspace.id
    @workspace.ensure_upload_directories!
    mapping_path = @workspace.mapping_dir.join("mapping.txt")
    File.write(mapping_path, "Well\tCondition\tStrain\nA1\tControl\tWT\n")
    session[:mapping_file_paths] = [mapping_path.to_s]
    session[:data_file_paths] = []
    session[:usr_data_file_paths] = []
    session[:usr_mapping_file_paths] = []
  end

  teardown do
    @workspace.clear_uploads!
  end

  test "review requires a subset column" do
    post :index, params: { chart_types: ["gp_plot"], gp_conditions: ["Control"] }

    assert_redirected_to selectanalyses_path
    assert_equal Job::GP_CONFIGURATION_ERROR, flash[:error]
  end

  test "review requires at least one subset value even when pooling is selected" do
    post :index, params: {
      chart_types: ["gp_plot"], gp_subset_column: "Condition", gp_pool_by_column: "Strain"
    }

    assert_redirected_to selectanalyses_path
    assert_equal Job::GP_CONFIGURATION_ERROR, flash[:error]
  end

  test "review accepts a subset without pooling" do
    post :index, params: {
      chart_types: ["gp_plot"], gp_subset_column: "Condition", gp_conditions: ["Control"],
      gp_pool_by_column: "", gp_subset_choice: "no"
    }

    assert_response :success
    assert_equal "'Condition:Control'", session[:gp_finalsubset]
    assert_equal "None", session[:gp_pool_by_column]
    assert_select "p", text: /Gaussian Process Plot \(Subset on Condition: Control;\s+No pooling\)/
  end

  test "review accepts a subset with pooling" do
    post :index, params: {
      chart_types: ["gp_plot"], gp_subset_column: "Condition", gp_conditions: ["Control"],
      gp_pool_by_column: "Strain"
    }

    assert_response :success
    assert_equal "'Condition:Control'", session[:gp_finalsubset]
    assert_select "p", text: /Subset on Condition: Control;\s+Pooled by Strain/
  end

  test "GP plot requires a mapping file" do
    session[:mapping_file_paths] = []
    post :index, params: {
      chart_types: ["gp_plot"], gp_subset_column: "Condition", gp_conditions: ["Control"]
    }

    assert_redirected_to selectanalyses_path
  end

  test "multiple filters and grouping columns are serialized and shown on review" do
    post :index, params: {
      chart_types: ["gp_plot"], gp_pool_replicates: "yes", gp_pool_columns: %w[Condition Strain],
      gp_subset_filters: {
        "0" => { column: "Condition", values: ["Control"] },
        "2" => { column: "Strain", values: %w[WT mutant] }
      }
    }

    assert_response :success
    assert_equal "'Condition:Control;Strain:WT,mutant'", session[:gp_finalsubset]
    assert_equal "Condition,Strain", session[:gp_pool_by_column]
    assert_select "p", text: /Subset on Condition: Control; Strain: WT, mutant;\s+Pooled by Condition, Strain/
  end

  test "pooling yes requires at least one grouping column" do
    post :index, params: {
      chart_types: ["gp_plot"], gp_pool_replicates: "yes",
      gp_subset_filters: { "0" => { column: "Condition", values: ["Control"] } }
    }

    assert_redirected_to selectanalyses_path
  end

  test "pooling no discards stale grouping columns" do
    post :index, params: {
      chart_types: ["gp_plot"], gp_pool_replicates: "no", gp_pool_columns: ["Strain"],
      gp_subset_filters: { "0" => { column: "Condition", values: ["Control"] } }
    }

    assert_response :success
    assert_equal "None", session[:gp_pool_by_column]
    assert_empty session[:gp_pool_columns]
  end

  test "rejects incomplete additional filters and duplicate subset columns" do
    [
      { column: "Strain", values: [] },
      { column: "Condition", values: ["Control"] },
      { column: "Unknown", values: ["Control"] }
    ].each do |second_filter|
      post :index, params: {
        chart_types: ["gp_plot"], gp_pool_replicates: "no",
        gp_subset_filters: { "0" => { column: "Condition", values: ["Control"] }, "1" => second_filter }
      }

      assert_redirected_to selectanalyses_path
    end
  end
end

class GenerateGpValidationTest < ActionController::TestCase
  tests GenerateController

  setup do
    @user = User.create!(email: "generate-gp-validation@example.com")
    @workspace = Job.create!(user: @user, status: Job::DRAFT_STATUS)
    session[:current_user_id] = @workspace.id
    @workspace.ensure_upload_directories!
    mapping_path = @workspace.mapping_dir.join("mapping.txt")
    File.write(mapping_path, "Well\tCondition\nA1\tControl\n")
    session[:chart_types] = ["gp_plot"]
    session[:mapping_file_paths] = [mapping_path.to_s]
    session[:gp_subset_column] = "Condition"
    session[:gp_conditions] = []
    data = @workspace.data_dir.join("data.txt")
    File.write(data, "OD\nTime\t#{(0...16).to_a.join("\t")}\nA1\t#{Array.new(16, 1).join("\t")}\n")
    session[:data_file_paths] = [data.to_s]

  end

  teardown do
    @workspace.clear_uploads!
    @user.jobs.each(&:clear_uploads!)
  end

  test "submission does not queue a GP plot without subset values" do
    assert_no_difference "Delayed::Job.count" do
      post :run
    end

    assert_redirected_to selectanalyses_path
    assert_equal Job::GP_CONFIGURATION_ERROR, flash[:error]
    assert_equal Job::DRAFT_STATUS, @workspace.reload.status
  end

  test "submission validates every filter before queueing" do
    session[:gp_subset_filters] = [
      { "column" => "Condition", "values" => ["Control"] },
      { "column" => "Unknown", "values" => ["WT"] }
    ]
    assert_no_difference "Delayed::Job.count" do
      post :run
    end
    assert_redirected_to selectanalyses_path
  end

  test "valid multi-filter submission queues all grouping columns" do
    File.write(session[:mapping_file_paths].first, "Well\tCondition\tStrain\tDose\nA1\tControl\tWT\t0\n")
    session[:gp_subset_filters] = [
      { "column" => "Condition", "values" => ["Control"] },
      { "column" => "Dose", "values" => ["0"] }
    ]
    session[:gp_pool_replicates] = "yes"
    session[:gp_pool_columns] = %w[Strain Dose]
    session[:gp_pool_by_column] = "Strain,Dose"
    session[:gp_finalsubset] = "'Condition:Control;Dose:0'"

    assert_difference "Delayed::Job.count", 1 do
      post :run, params: { email: @user.email }
    end

    queued = Delayed::Job.order(:id).last.payload_object
    assert_equal "Strain,Dose", queued.gp_pool_by_column
    assert_equal "'Condition:Control;Dose:0'", queued.gp_finalsubset
  end
end

class SelectGpControlsTest < ActionController::TestCase
  tests SelectanalysesController

  test "restores multiple filters and grouping columns when returning from review" do
    @user = User.create!(email: "gp-controls@example.com")
    job = Job.create!(user: @user, status: Job::DRAFT_STATUS)
    session[:current_user_id] = job.id
    job.ensure_upload_directories!
    mapping = job.mapping_dir.join("mapping.txt")
    File.write(mapping, "Well\tCondition\tStrain\tDose\nA1\t(--Fe)\tWT\t0\nA2\t(--Fe)\tmutant\t10\n")
    session[:mapping_file_paths] = [mapping.to_s]
    session[:chart_types] = ["gp_plot"]
    session[:gp_subset_filters] = [
      { "column" => "Condition", "values" => ["(--Fe)"] },
      { "column" => "Strain", "values" => ["WT", "mutant"] }
    ]
    session[:gp_pool_replicates] = "yes"
    session[:gp_pool_columns] = %w[Strain Dose]

    get :index, params: { returning_from_review: "true" }

    assert_response :success
    assert_select "input[name='gp_pool_replicates'][value='yes'][checked]"
    assert_select "input[name='gp_pool_columns[]'][checked]", count: 2
    assert_select "input[name='gp_pool_columns[]'][value='Well']", count: 0
    assert_select "button#gp-add-filter", text: "Add another filter"
    assert_includes response.body, '"values":["WT","mutant"]'
  ensure
    job&.clear_uploads!
  end
end
