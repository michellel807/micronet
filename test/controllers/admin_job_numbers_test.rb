require "test_helper"

class AdminJobNumbersTest < ActionController::TestCase
  tests Admin::JobsController

  test "dashboard shows submitted numbers and excludes unfinished attempts" do
    session[:admin_id] = admins(:one).id
    submitted_user = User.create!(email: "numbered-job@example.com")
    submitted = submitted_user.jobs.create!(status: "Job submitted", submission_number: 812)
    unfinished_user = User.create!(email: "unfinished-job@example.com")
    unfinished_user.jobs.create!(status: Job::DRAFT_STATUS)

    get :index

    assert_response :success
    assert_select ".c-id", text: "#812"
    assert_not_includes response.body, unfinished_user.email
    assert_includes response.body, "showCancelModal(#{submitted.id}, &quot;#{submitted_user.email}&quot;, 812)"
  end
end
