require "test_helper"

class GenerateSubmissionEmailTest < ActionController::TestCase
  tests GenerateController

  setup do
    @user = User.create!(email: "generate-submission@example.com")
    @workspace = Job.create!(user: @user, status: Job::DRAFT_STATUS)
    session[:current_user_id] = @workspace.id
    @data = @workspace.data_dir.join("file1.txt")
    @mapping = @workspace.mapping_dir.join("file1.txt")
    File.write(@data, "Time\t0\t1\nA1\t0.1\t0.2\n")
    File.write(@mapping, "Well\tStrain\tMedium\nA1\tWT\tLB\n")
    session[:data_file_paths] = [@data.to_s]
    session[:mapping_file_paths] = [@mapping.to_s]
    session[:chart_types] = ["fit_stats"]
    session[:pool_replicates] = "yes"
    session[:pool_options] = ["Strain", "Medium"]
    session[:pool_options_string] = "'Strain,Medium'"
    session[:gp_time_step_size] = 2
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    @workspace.clear_uploads!
    @user.jobs.each(&:clear_uploads!)
  end

  test "submission persists choices before sending its confirmation" do
    assert_difference "Delayed::Job.count", 1 do
      post :run, params: { email: @user.email }
    end

    assert_redirected_to "/generate"
    @job = Job.find(session[:current_user_id])
    assert_equal "Strain, Medium", @job.reload.submission_options["Fit Statistics pooling"]
    message = ActionMailer::Base.deliveries.last
    assert_includes message.subject, "[Job ##{@job.id}]"
    assert_includes message.text_part.body.decoded, "Fit Statistics (Pool by Strain, Medium)"
    assert_includes message.text_part.body.decoded, "Gaussian Process time step size: 2"
  end

end
