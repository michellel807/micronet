require "test_helper"

class JobCancellationTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
    @user = User.create!(email: "job-cancellation-#{SecureRandom.hex(6)}@example.com")
    @job = Job.create!(user: @user, status: "Job submitted")
  end

  test "cancelling a queued job removes only its pending analyzer and emails the user" do
    other_user = User.create!(email: "other-job-cancellation-#{SecureRandom.hex(6)}@example.com")
    other_job = Job.create!(user: other_user, status: "Job submitted")
    queued_job = Delayed::Job.enqueue(analyzer_for(@job))
    other_queued_job = Delayed::Job.enqueue(analyzer_for(other_job))

    @job.mark_cancelled

    assert_equal "Cancelled", @job.reload.status
    assert_not Delayed::Job.exists?(queued_job.id)
    assert Delayed::Job.exists?(other_queued_job.id)
    assert_equal [@user.email], ActionMailer::Base.deliveries.last.to
  end

  test "a cancelled queued analyzer exits without starting the analysis" do
    @job.update!(status: "Cancelled")
    analyzer = analyzer_for(@job)
    @job.stub(:analyze, ->(*) { flunk "cancelled analysis should not start" }) do
      Job.stub(:find, @job) do
        analyzer.perform
      end
    end
  end

  test "completed jobs cannot be cancelled" do
    @job.update!(status: "Completed")

    assert_not @job.mark_cancelled
    assert_equal "Completed", @job.reload.status
    assert_empty ActionMailer::Base.deliveries
  end

  test "a running command is terminated when cancellation is observed" do
    checks = 0
    @job.stub(:cancelled?, -> { checks += 1; checks > 1 }) do
      assert_raises(Job::Cancelled) do
        @job.run_cancellable_command("sleep", "30")
      end
    end
  end

  private

  def analyzer_for(job)
    JobAnalyzer.new(job.id, *Array.new(14))
  end
end
