require "test_helper"

class FilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "files-controller-test@example.com")
    @job = Job.create!(user: @user, status: Job::DRAFT_STATUS)
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
    get serve_job_image_path(job_id: @job.id, filename: @filename)

    assert_response :success
  end

  test "returns not found when job id is invalid" do
    get serve_job_image_path(job_id: -1, filename: @filename)

    assert_response :not_found
  end

  test "returns not found when filename is unsafe" do
    get serve_job_image_path(job_id: @job.id, filename: "..evil.png")

    assert_response :not_found
  end

  test "returns not found when requested file does not exist" do
    get serve_job_image_path(job_id: @job.id, filename: "missing.png")

    assert_response :not_found
  end

  test "legacy image route returns not found without job context" do
    get "/uploads/userexpt/figures/#{@filename}"

    assert_response :not_found
  end

  test "download returns attachment for valid figure" do
    get download_job_figure_path(job_id: @job.id, filename: @filename)

    assert_response :success
    assert_match "attachment", response.headers["Content-Disposition"]
  end
end
