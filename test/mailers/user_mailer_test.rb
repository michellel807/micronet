require "test_helper"

class UserMailerTest < ActionMailer::TestCase
  setup do
    @user = User.create!(email: "submission-mail@example.com")
    @job = Job.create!(user: @user, status: "Job submitted", submission_number: 812, submission_options: {
      "Analyses" => "Gaussian Process Plot",
      "Gaussian Process subset" => "Strain: <control>",
      "Gaussian Process pooling" => "None"
    })
  end

  test "submission and problem notifications identify the job and include saved choices" do
    messages = [
      UserMailer.with(job: @job).confirm_email,
      UserMailer.failedjob_email(@job, "Analysis failed"),
      UserMailer.job_cancelled_email(@job),
      UserMailer.failed_heatmap_email(@job, "Heatmap failed"),
      UserMailer.with(job: @job).admin_email
    ]

    messages.each do |message|
      assert_includes message.subject, "[Job ##{@job.submission_number}]"
      assert_includes (message.html_part || message).body.decoded, "Strain: &lt;control&gt;"
      if message.text_part
        assert_includes message.text_part.body.decoded, "Strain: <control>"
      end
    end
  end

  test "older jobs without saved choices still render" do
    @job.update!(submission_options: {})
    message = UserMailer.processedjob_email([], @job)

    assert_includes message.subject, "[Job ##{@job.submission_number}]"
    assert_includes message.text_part.body.decoded, "Attached is your final analyzed data."
  end

  test "results omit submission details and unchanged time step settings" do
    [1, 3].each do |requested|
      message = UserMailer.processedjob_email([], @job, {
        "Gaussian Process Plot" => { requested: requested, used: requested, retried: false }
      }, requested)

      assert_includes message.subject, "[Job ##{@job.submission_number}]"
      [message.html_part, message.text_part].each do |part|
        body = part.body.decoded
        assert_not_includes body, "Submission Details"
        assert_not_includes body, "Uploaded Files"
        assert_not_includes body, "Analyses To Run"
        assert_not_includes body, "time step"
        assert_not_includes body, "MicroNet Adjusted This Job"
        assert_not_includes body, "Strain:"
      end
    end
  end

  test "results explain automatic time step changes and preserve analysis warnings" do
    message = UserMailer.processedjob_email([], @job, {
      "Gaussian Process Plot" => { requested: 1, used: 11, retried: true, high_impact: true }
    }, 1, [{ analysis: "Fit Statistics", message: "Available memory exceeded", attempted_tss: [1, 3] }])

    [message.html_part, message.text_part].each do |part|
      body = Nokogiri::HTML(part.body.decoded).text
      assert_includes body, "MicroNet Adjusted This Job"
      assert_match(/Started with time step size:\s*1/, body)
      assert_match(/Completed using time step size:\s*11/, body)
      assert_includes body, "high time step size"
      assert_includes body, "Some Analyses Could Not Be Completed"
      assert_includes body, "Available memory exceeded"
      assert_not_includes body, "Submission Details"
      assert_not_includes body, "Your Time Step Setting"
    end
  end

  test "renders filenames and analyses in separate review-style sections" do
    @job.update!(submission_options: SubmissionSummary.from_session({
      chart_types: %w[gp_plot fit_stats], gp_subset_column: "condition",
      gp_conditions: ["(--Fe)"], gp_pool_by_column: "None", pool_replicates: "no",
      usr_data_file_paths: ["/private/uploads/data <1>.txt"],
      usr_mapping_file_paths: ["mapping cleaned 1.txt"],
      usr_meta_file_path: "metadata.txt", usr_interval_file_path: "interval.txt"
    }))
    message = UserMailer.with(job: @job.reload).confirm_email
    html = Nokogiri::HTML(message.html_part.body.decoded)

    assert_includes html.css("h3").map(&:text), "Uploaded Files"
    assert_includes html.css("h3").map(&:text), "Analyses To Run"
    assert_includes html.css("p").map(&:text), "Data Files: data <1>.txt"
    assert_includes html.css("p").map(&:text), "Gaussian Process Plot (Subset on condition: (--Fe); No pooling)"
    assert_includes html.css("p").map(&:text), "Fit Statistics (No pooling)"
    assert_includes message.html_part.body.decoded, "data &lt;1&gt;.txt"
    %w[metadata.txt interval.txt].each do |filename|
      assert_includes message.text_part.body.decoded, filename
    end
    assert_includes message.text_part.body.decoded, "Mapping Files: mapping cleaned 1.txt"
    assert_not_includes message.text_part.body.decoded, "/private/uploads"
  end
end
