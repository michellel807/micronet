require "test_helper"

class SubmissionSummaryTest < ActiveSupport::TestCase
  test "captures original filenames and review-style analysis descriptions" do
    summary = SubmissionSummary.from_session({
      chart_types: %w[gp_plot fit_stats], gp_subset_column: "condition",
      gp_conditions: ["(--Fe)"], gp_pool_by_column: "None", pool_replicates: "no",
      usr_data_file_paths: ["/uploads/221108dtxRtitration.txt"],
      usr_mapping_file_paths: ["221108dtxRtitration_mapping_cleaned 1.txt"],
      usr_interval_file_path: "titration_interval.txt"
    })

    assert_equal ["221108dtxRtitration.txt"], summary["Uploaded Files"]["Data Files"]
    assert_equal ["221108dtxRtitration_mapping_cleaned 1.txt"], summary["Uploaded Files"]["Mapping Files"]
    assert_equal ["titration_interval.txt"], summary["Uploaded Files"]["Interval File"]
    assert_not summary["Uploaded Files"].key?("Meta File")
    assert_equal [
      "Gaussian Process Plot (Subset on condition: (--Fe); No pooling)",
      "Fit Statistics (No pooling)"
    ], summary["Analyses To Run"]
  end

  test "captures selected analyses and excludes stale options for other analyses" do
    summary = SubmissionSummary.from_session({
      chart_types: %w[gp_plot fit_stats], gp_subset_column: "Strain",
      gp_conditions: %w[WT mutant], gp_pool_by_column: "Medium",
      pool_replicates: "yes", pool_options: %w[Strain Medium],
      heatmap_value: "Growth Rate", gp_time_step_size: 3
    })

    assert_equal "Gaussian Process Plot, Fit Statistics", summary["Analyses"]
    assert_equal "Strain: WT, mutant", summary["Gaussian Process subset"]
    assert_equal "Medium", summary["Gaussian Process pooling"]
    assert_equal "Strain, Medium", summary["Fit Statistics pooling"]
    assert_equal 3, summary["Gaussian Process time step size"]
    assert_not summary.key?("Heatmap value")
  end

  test "captures heatmap and comparison settings" do
    summary = SubmissionSummary.from_session({
      chart_types: %w[heatmap_plot test-hypothesis compare-parameters],
      heatmap_value: "Growth Rate", heatmap_x: "Strain", heatmap_y: "Medium",
      column_test: "Strain", test_finalsubset: "'Strain:WT,mutant;Medium:LB'",
      hypothesis: "'H0:Time;H1:Time+Strain'", compare_parameters_pool: "Strain",
      compare_finalsubset: "'Strain:WT,mutant;Medium:LB'"
    })

    assert_equal "Growth Rate", summary["Heatmap value"]
    assert_equal "Strain", summary["Heatmap X axis"]
    assert_equal "Medium", summary["Heatmap Y axis"]
    assert_equal "Strain:WT,mutant;Medium:LB", summary["Hypothesis test conditions and subset"]
    assert_equal "H0:Time;H1:Time+Strain", summary["Hypothesis"]
    assert_equal "Strain", summary["Compare Growth pooling"]
    assert_equal "Strain:WT,mutant;Medium:LB", summary["Compare Growth conditions and subset"]
    assert_equal Job::DEFAULT_TSS, summary["Gaussian Process time step size"]
  end
end
