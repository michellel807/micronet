require "test_helper"

class TemporaryUploadFlowTest < ActionDispatch::IntegrationTest
  setup do
    @email = "temporary-flow@example.com"
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    User.find_by(email: @email)&.jobs&.each(&:clear_uploads!)
    UploadWorkspace.find(session[:upload_token])&.clear_uploads!
  end

  test "upload edit and review create no job until submit then queue permanent inputs" do
    assert_no_difference "Job.count" do
      post "/", params: { email: @email }
      assert_redirected_to upload_path
      follow_redirect!
      assert_response :success

      post upload_path, params: {
        data_pair_files: { "1" => Rack::Test::UploadedFile.new(Rails.root.join("lib/examplefiles/data/exampledata1.txt"), "text/plain") },
        mapping_pair_files: { "1" => Rack::Test::UploadedFile.new(Rails.root.join("lib/examplefiles/mapping/examplemapping1.txt"), "text/plain") },
        gp_time_step_size: "1"
      }
      assert_redirected_to selectanalyses_path
      follow_redirect!
      assert_response :success

      post review_path, params: { chart_types: ["fit_stats"], pool_replicates: "no" }
      assert_response :success
      assert_includes response.body, "examplemapping1.txt"

      get upload_path
      assert_response :success
      assert_includes response.body, '"mapping_name":"examplemapping1.txt"'
      post upload_path, params: { retained_pairs: { "1" => "0" }, gp_time_step_size: "1" }
      assert_redirected_to selectanalyses_path
      post review_path, params: { chart_types: ["fit_stats"], pool_replicates: "no" }
      assert_response :success
    end

    token = session[:upload_token]
    assert_difference ["Job.count", "Delayed::Job.count"], 1 do
      post "/generate"
      assert_redirected_to "/generate"
    end

    job = Job.find_by!(upload_token: token)
    assert_equal job.id, job.job_number
    assert job.data_dir.join("file1.txt").file?
    assert job.mapping_dir.join("file1.txt").file?
    assert_not UploadWorkspace.find(token)
    assert_includes ActionMailer::Base.deliveries.last.subject, "[Job ##{job.id}]"
    follow_redirect!
    assert_response :success

    assert_no_difference ["Job.count", "Delayed::Job.count"] do
      post "/generate"
    end
  end

  test "missing and expired sessions redirect to begin without creating jobs" do
    assert_no_difference "Job.count" do
      get upload_path
      assert_redirected_to root_path
      post "/", params: { email: @email }
      workspace = UploadWorkspace.find(session[:upload_token])
      File.utime(25.hours.ago.to_time, 25.hours.ago.to_time, workspace.upload_root)
      get selectanalyses_path
      assert_redirected_to root_path
      assert_includes flash[:alert], "no longer available"
    end
  end
end
