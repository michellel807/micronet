require "test_helper"

class FilesControllerTest < ActionController::TestCase
  tests FilesController
  setup do
    @user = User.create!(email: "files-controller-test@example.com")
    @job = Job.create!(user: @user, status: Job::DRAFT_STATUS)
    session[:user_id] = @user.id
    session[:current_user_id] = @job.id
    @job.ensure_upload_directories!
    @filename = "growth_plot.png"
    @file_path = @job.figures_dir.join(@filename)
    File.write(@file_path, "fake image bytes")
  end

  teardown do
    @job&.clear_uploads!
    @job&.destroy
    @user&.destroy
  end

  test "serves job figure when job and filename are valid" do
    get :serve_image, params: { job_id: @job.id, filename: @filename }

    assert_response :success
  end

  test "returns not found when job id is invalid" do
    get :serve_image, params: { job_id: -1, filename: @filename }

    assert_response :not_found
  end

  test "returns not found when filename is unsafe" do
    get :serve_image, params: { job_id: @job.id, filename: "..evil.png" }

    assert_response :not_found
  end

  test "returns not found when requested file does not exist" do
    get :serve_image, params: { job_id: @job.id, filename: "missing.png" }

    assert_response :not_found
  end

  test "download returns attachment for valid figure" do
    get :download, params: { job_id: @job.id, filename: @filename }

    assert_response :success
    assert_match "attachment", response.headers["Content-Disposition"]
  end
  test "anonymous and unrelated sessions cannot read another job" do
    session.clear
    get :serve_image, params: { job_id: @job.id, filename: @filename }
    assert_response :not_found

    session[:user_id] = @user.id
    get :download, params: { job_id: @job.id, filename: @filename }
    assert_response :not_found
  end

  test "administrators can access job results" do
    session.clear
    session[:admin_id] = admins(:one).id
    get :serve_image, params: { job_id: @job.id, filename: @filename }
    assert_response :success
  end

  test "symlinks cannot expose files outside the figures directory" do
    outside = @job.upload_root.join("secret.txt")
    outside.write("private input")
    File.symlink(outside, @job.figures_dir.join("linked.txt"))
    get :download, params: { job_id: @job.id, filename: "linked.txt" }
    assert_response :not_found
  end
end
