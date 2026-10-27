require "test_helper"

class AdminSecurityTest < ActionController::TestCase
  tests AdminController

  setup { AdminController::LOGIN_RATE_LIMIT_STORE.clear }
  teardown { AdminController::LOGIN_RATE_LIMIT_STORE.clear }

  test "login resets the pre-authentication session" do
    admin = Admin.create!(username: "security-test", password: "unique-test-password")
    session[:untrusted] = "old session"
    post :authenticate_admin, params: { username: admin.username, password: "unique-test-password" }
    assert_redirected_to admin_jobs_path
    assert_equal admin.id, session[:admin_id]
    assert_nil session[:untrusted]
  end

  test "repeated login attempts are throttled" do
    10.times { post :authenticate_admin, params: { username: "missing", password: "incorrect" } }
    post :authenticate_admin, params: { username: "missing", password: "incorrect" }
    assert_response :too_many_requests
  end

  test "a deleted administrator cannot use an old session" do
    session[:admin_id] = -1
    patch :update_username, params: { new_username: "changed" }
    assert_redirected_to login_path
  end
end
