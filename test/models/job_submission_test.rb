require "test_helper"
require "minitest/mock"

class JobSubmissionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "submit-workspace@example.com")
    @workspace = UploadWorkspace.create!
    @data = @workspace.data_dir.join("file1.txt")
    @mapping = @workspace.mapping_dir.join("file1.txt")
    File.write(@data, "OD\nTime\t0\t1\nA1\t0.1\t0.2\n")
    File.write(@mapping, "Well\tCondition\nA1\tControl\n")
    @workspace.pair_metadata_path.write({ pairs: [{ pair_key: "file1", original_data_filename: "data.txt" }] }.to_json)
    @choices = {
      data_file_paths: [@data.to_s], mapping_file_paths: [@mapping.to_s],
      usr_data_file_paths: ["data.txt"], usr_mapping_file_paths: ["mapping.txt"],
      chart_types: ["fit_stats"], pool_replicates: "yes", pool_options: ["Condition"],
      gp_time_step_size: 1
    }
  end

  teardown do
    @workspace.clear_uploads!
    @user.jobs.each(&:clear_uploads!)
  end

  test "submission creates the job and transfers every input before queueing" do
    interval = @workspace.parameters_dir.join("interval.txt")
    interval.write("file1\t600\n")
    original = @workspace.upload_root.join("originals", "data", "file1.txt")
    FileUtils.mkdir_p(original.parent)
    original.write("original input")
    job = nil

    assert_difference "Job.count", 1 do
      assert_difference "Delayed::Job.count", 1 do
        job, created = JobSubmission.call(user: @user, workspace: @workspace, choices: @choices)
        assert created
      end
    end

    assert_nil @user.jobs.where(status: Job::DRAFT_STATUS).first
    assert_equal job.id, job.job_number
    assert_nil job.submission_number
    assert_not_nil job.confirm_time
    assert_equal File.read(job.data_dir.join("file1.txt")), "OD\nTime\t0\t1\nA1\t0.1\t0.2\n"
    assert job.mapping_dir.join("file1.txt").file?
    assert job.parameters_dir.join("interval.txt").file?
    assert_equal "original input", job.upload_root.join("originals/data/file1.txt").read
    assert_equal job.id, JSON.parse(job.pair_metadata_path.read)["job_id"]
    assert_not @workspace.upload_root.exist?
    queued = Delayed::Job.order(:id).last.payload_object
    assert_equal job.id, queued.job_id
    assert_equal "Condition", queued.pool_options_string
    assert_equal ["data.txt"], job.submission_options["Uploaded Files"]["Data Files"]
  end

  test "repeated submission returns the existing job without queueing again" do
    first, = JobSubmission.call(user: @user, workspace: @workspace, choices: @choices)
    assert_no_difference ["Job.count", "Delayed::Job.count"] do
      second, created = JobSubmission.call(user: @user, workspace: @workspace, choices: @choices)
      assert_equal first.id, second.id
      assert_not created
    end
  end

  test "enqueue failure restores temporary files and permits a retry" do
    other = @user.jobs.create!(status: "Completed")
    other.ensure_upload_directories!
    marker = other.data_dir.join("existing-input.txt")
    marker.write("must remain intact")
    assert_no_difference ["Job.count", "Delayed::Job.count"] do
      Delayed::Job.stub(:enqueue, ->(*) { raise "Queue unavailable" }) do
        assert_raises(RuntimeError) do
          JobSubmission.call(user: @user, workspace: @workspace, choices: @choices)
        end
      end
    end
    assert File.file?(@data)
    assert File.file?(@mapping)
    assert_equal "must remain intact", marker.read
    assert_not JSON.parse(@workspace.pair_metadata_path.read).key?("job_id")
    job, created = JobSubmission.call(user: @user, workspace: @workspace, choices: @choices)
    assert created
    assert job.data_dir.join("file1.txt").file?
  end

  test "permanent storage refuses an unsaved job without an ID" do
    assert_raises(ArgumentError) { Job.new.upload_root }
  end

  test "the active-job limit is checked again at submission" do
    Job::MAX_ACTIVE_JOBS_PER_USER.times { @user.jobs.create!(status: "Job submitted") }
    assert_no_difference ["Job.count", "Delayed::Job.count"] do
      assert_raises(JobSubmission::LimitReached) do
        JobSubmission.call(user: @user, workspace: @workspace, choices: @choices)
      end
    end
    assert File.file?(@data)
  end

  test "missing inputs never create a job" do
    File.delete(@mapping)
    assert_no_difference "Job.count" do
      assert_raises(JobSubmission::InvalidUploads) do
        JobSubmission.call(user: @user, workspace: @workspace, choices: @choices)
      end
    end
  end

  test "old submitted numbers remain unchanged" do
    old = @user.jobs.create!(status: "Completed", submission_number: 812)
    assert_equal 812, old.reload.job_number
  end
end
