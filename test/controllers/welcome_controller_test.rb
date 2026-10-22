require "test_helper"

class WelcomeControllerTest < ActionController::TestCase
  tests WelcomeController

  setup do
    @user = User.create!(email: "fresh-submission@example.com")
    @workspace = UploadWorkspace.create!
    @mapping = @workspace.mapping_dir.join("mapping.txt")
    File.write(@mapping, "Well\tCondition\nA1\tControl\n")
    session[:user_id] = @user.id
    session[:upload_token] = @workspace.token
    session[:mapping_file_paths] = [@mapping.to_s]
    session[:chart_types] = ["gp_plot"]
    session[:gp_pool_columns] = ["Condition"]
  end

  teardown do
    @workspace.clear_uploads!
    UploadWorkspace.find(session[:upload_token])&.clear_uploads!
  end

  test "begin creates only a fresh workspace and discards previous temporary files" do
    submitted = @user.jobs.create!(status: "Job submitted")
    session[:admin_id] = admins(:one).id

    assert_no_difference "Job.count" do
      post :create, params: { email: @user.email }
    end

    assert_redirected_to upload_path
    assert_not File.exist?(@mapping)
    assert Job.exists?(submitted.id)
    assert_not_equal @workspace.token, session[:upload_token]
    assert UploadWorkspace.find(session[:upload_token])
    %i[current_user_id mapping_file_paths chart_types gp_pool_columns].each do |key|
      assert_nil session[key]
    end
    assert_equal @user.email, session[:email]
    assert_equal admins(:one).id, session[:admin_id]
  end

  test "home has no resume option" do
    get :index, params: { email: @user.email }
    assert_response :success
    assert_select "form[action='/resume_job']", count: 0
    assert_not_includes response.body, "Would you like to resume?"
  end

  test "invalid email does not discard current inputs" do
    assert_no_difference "Job.count" do
      post :create, params: { email: "invalid" }
    end
    assert_response :success
    assert_includes response.body, "Invalid Email"
    assert File.exist?(@mapping)
  end

  test "active-job limit remains enforced" do
    Job::MAX_ACTIVE_JOBS_PER_USER.times { @user.jobs.create!(status: "Job submitted") }
    assert_no_difference "Job.count" do
      post :create, params: { email: @user.email }
    end
    assert_response :success
    assert_includes response.body, "You already have #{Job::MAX_ACTIVE_JOBS_PER_USER} jobs"
    assert File.exist?(@mapping)
  end
end
