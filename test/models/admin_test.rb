require "test_helper"

class AdminTest < ActiveSupport::TestCase
  test "new administrators need a password of at least 12 characters" do
    admin = Admin.new(username: "short-password-test", password: "admin123")
    assert_not admin.valid?
    assert admin.errors[:password].present?
  end

  test "seeding never overwrites an existing administrators password" do
    admin = Admin.create!(username: "admin", password: "original-safe-password")
    original_digest = admin.password_digest
    load Rails.root.join("db/seeds.rb").to_s
    assert_equal original_digest, admin.reload.password_digest
  end

  test "initial seeding requires an explicitly supplied password" do
    original = ENV.delete("ADMIN_INITIAL_PASSWORD")
    error = assert_raises(RuntimeError) { load Rails.root.join("db/seeds.rb").to_s }
    assert_includes error.message, "ADMIN_INITIAL_PASSWORD"
    assert_not Admin.exists?(username: "admin")
  ensure
    ENV["ADMIN_INITIAL_PASSWORD"] = original if original
  end
end
