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

  test "growth subjects are unchanged and RNA-seq jobs are named in every subject" do
    assert_equal "Schmid Lab Microbial Growth Model: Job Failed [Job #812]", UserMailer.failedjob_email(@job, "x").subject

    rnaseq = Job.create!(user: @user, status: "Job submitted", analysis_type: "rnaseq",
                         submission_options: { "Comparison" => "treated vs <control> (reference)" })
    [UserMailer.with(job: rnaseq).confirm_email, UserMailer.failedjob_email(rnaseq, "x"), UserMailer.job_cancelled_email(rnaseq)].each do |message|
      assert message.subject.start_with?("Schmid Lab RNA-seq Analysis: "), message.subject
      assert_includes message.html_part.body.decoded, "treated vs &lt;control&gt; (reference)"
    end
  end

  test "RNA-seq results summarize the comparison, list attachments and explain warnings" do
    rnaseq = Job.create!(user: @user, status: "Completed", analysis_type: "rnaseq")
    manifest = {
      "design" => "~ batch + condition",
      "contrast" => { "test_level" => "treated", "reference_level" => "control" },
      "samples" => { "in_model" => 8 },
      "genes" => { "in_input" => 2000, "tested" => 1951, "significant" => 209, "significant_up" => 109, "significant_down" => 100 }
    }
    Dir.mktmpdir do |directory|
      zip = File.join(directory, "rnaseq_results_job#{rnaseq.job_number}.zip")
      File.binwrite(zip, "PK\x03\x04")
      message = UserMailer.rnaseq_results_email(rnaseq, [zip], manifest, [{ analysis: "Plots", message: "Could not draw <plots>" }])

      assert_equal "Schmid Lab RNA-seq Analysis: Processed Data [Job ##{rnaseq.job_number}]", message.subject
      assert_equal [File.basename(zip)], message.attachments.map(&:filename)
      assert_equal "PK\x03\x04".b, message.attachments.first.decoded.b
      assert_includes message.html_part.body.decoded, "Could not draw &lt;plots&gt;"
      [Nokogiri::HTML(message.html_part.body.decoded).text, message.text_part.body.decoded].each do |text|
        body = text.squish
        assert_includes body, "compared treated with control (the reference)"
        assert_includes body, "Design: ~ batch + condition"
        assert_includes body, "Genes tested: 1951 of 2000"
        assert_includes body, "Significant genes: 209 (109 higher and 100 lower in treated)"
        assert_includes body, "Plots: Could not draw <plots>"
        assert_not_includes body, "Submission Details"
        assert_not_includes body, "time step"
      end
    end
  end

  test "time-course results state the question and do not claim a direction" do
    rnaseq = Job.create!(user: @user, status: "Completed", analysis_type: "rnaseq")
    manifest = {
      "design" => "full: ~ condition + time + condition:time; reduced: ~ condition + time (likelihood ratio test)",
      "question" => "Which genes change differently over time in treated than in control (the reference)?",
      "contrast" => { "test_level" => "treated", "reference_level" => "control" },
      "time" => { "column" => "time", "levels" => %w[0 6 24] },
      "samples" => { "in_model" => 18 },
      "genes" => { "in_input" => 2000, "tested" => 1980, "significant" => 190, "significant_up" => nil, "significant_down" => nil }
    }
    message = UserMailer.rnaseq_results_email(rnaseq, [], manifest, [])
    [Nokogiri::HTML(message.html_part.body.decoded).text, message.text_part.body.decoded].each do |text|
      body = text.squish
      assert_includes body, "It tested: Which genes change differently over time in treated than in control (the reference)?"
      assert_includes body, "Significant genes: 190"
      assert_not_includes body, "higher and"
      assert_not_includes body, "Gene clusters"
      assert_not_includes body, "reliability"
    end
  end

  test "time-course results summarize the clusters and the silhouette reliability check" do
    rnaseq = Job.create!(user: @user, status: "Completed", analysis_type: "rnaseq")
    manifest = {
      "design" => "full: ~ time; reduced: ~ 1 (likelihood ratio test)", "question" => "Which genes change over time?",
      "time" => { "column" => "time", "levels" => %w[0 6 24] }, "samples" => { "in_model" => 9 },
      "genes" => { "in_input" => 2000, "tested" => 1980, "significant" => 190, "significant_up" => nil, "significant_down" => nil },
      "clustering" => { "status" => "completed", "clusters" => 4, "silhouette" => 0.4411 }
    }
    plain = UserMailer.rnaseq_results_email(rnaseq, [], manifest, []).text_part.body.decoded.squish
    assert_includes plain, "Gene clusters: 4 (silhouette 0.44)"
    assert_not_includes plain, "reliability"

    manifest["clustering"]["silhouette_baseline"] = { "k" => 4, "actual" => 0.4411, "shuffled_mean" => 0.0328,
                                                      "difference" => 0.4082, "shuffles" => 5 }
    message = UserMailer.rnaseq_results_email(rnaseq, [], manifest, [])
    [Nokogiri::HTML(message.html_part.body.decoded).text, message.text_part.body.decoded].each do |text|
      assert_includes text.squish, "Silhouette reliability check: actual 0.44, shuffled baseline 0.03, difference +0.41"
    end
  end
end
