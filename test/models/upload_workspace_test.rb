require "test_helper"

class UploadWorkspaceTest < ActiveSupport::TestCase
  teardown do
    Array(@workspaces).each(&:clear_uploads!)
  end

  def workspace
    entry = UploadWorkspace.create!
    (@workspaces ||= []) << entry
    entry
  end

  test "unsubmitted uploads have random tokens and never create job records" do
    assert UploadDirectories.root.to_s.start_with?(Rails.root.join("tmp/test-uploads").to_s + "/")
    assert_no_difference "Job.count" do
      first = workspace
      second = workspace
      assert_match UploadWorkspace::TOKEN_FORMAT, first.token
      assert_not_equal first.token, second.token
      first.discard!
      assert_not first.upload_root.exist?
    end
  end

  test "invalid tokens cannot address other directories" do
    assert_nil UploadWorkspace.find("../../jobs/1")
    assert_nil UploadWorkspace.find(nil)
    assert_raises(ArgumentError) { UploadWorkspace.new("../jobs") }
  end

  test "cleanup deletes expired workspaces and preserves active uploads and submitted files" do
    expired = workspace
    fresh = workspace
    File.utime(25.hours.ago.to_time, 25.hours.ago.to_time, expired.upload_root)
    user = User.create!(email: "cleanup-submitted@example.com")
    job = user.jobs.create!(status: "Completed")
    job.ensure_upload_directories!

    assert_operator UploadWorkspace.cleanup_expired!, :>=, 1
    assert_not expired.upload_root.exist?
    assert fresh.upload_root.exist?
    assert job.upload_root.exist?
  ensure
    job&.clear_uploads!
  end

  test "cleanup skips a workspace while an upload holds its lock" do
    busy = workspace
    busy.with_lock do
      File.utime(25.hours.ago.to_time, 25.hours.ago.to_time, busy.upload_root)
      UploadWorkspace.cleanup_expired!
      assert busy.upload_root.exist?
    end
  end

  test "expired sessions cannot revive their uploads" do
    expired = workspace
    File.utime(25.hours.ago.to_time, 25.hours.ago.to_time, expired.upload_root)
    assert_raises(UploadWorkspace::Expired) { expired.with_lock { flunk "expired uploads must be rejected" } }
  end

  test "cleanup is scheduled once and schedules its next hourly run" do
    assert_difference "Delayed::Job.where(queue: UploadWorkspaceCleanup::QUEUE).count", 1 do
      2.times { UploadWorkspaceCleanup.schedule! }
    end
    job = Delayed::Job.where(queue: UploadWorkspaceCleanup::QUEUE).last
    assert_difference "Delayed::Job.where(queue: UploadWorkspaceCleanup::QUEUE).count", 1 do
      job.payload_object.perform
    end
    following = Delayed::Job.where(queue: UploadWorkspaceCleanup::QUEUE).order(:id).last
    assert_in_delta 1.hour.from_now.to_i, following.run_at.to_i, 5
  end
end
