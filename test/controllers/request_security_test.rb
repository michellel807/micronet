require "test_helper"

class RequestSecurityTest < ActionDispatch::IntegrationTest
  test "workflow posts require a CSRF token" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    ["/upload", "/review", "/selectanalyses", "/generate"].each do |path|
      assert_raises(ActionController::InvalidAuthenticityToken) { post path }
    end
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "GET cannot delete uploads" do
    assert_raises(ActionController::RoutingError) { get "/upload/delete_files" }
  end
end
