# The RNA-seq wizard: upload a count matrix and sample sheet, choose the
# comparison, review, and submit. Submission reuses JobSubmission, which moves
# the workspace into the job and queues RnaSeqAnalyzer.
class RnaSeqController < ApplicationController
  FILE_KINDS = { "counts" => "count matrix", "metadata" => "sample sheet", "annotations" => "annotation table" }.freeze
  REQUIRED_KINDS = %w[counts metadata].freeze
  EXAMPLE_FILES = %w[counts.tsv sample_metadata.tsv annotations.tsv
                     timecourse_counts.tsv timecourse_sample_metadata.tsv timecourse_annotations.tsv].freeze

  before_action :require_upload_workspace, except: :example
  before_action :require_rnaseq_session, except: :example
  before_action :load_inputs, only: %i[configure save_configuration review]
  helper_method :rnaseq_steps

  def upload_form
    @files = stored_files
    render :upload
  end

  def upload
    error = nil
    lock_upload_workspace do
      error = save_uploads
    end
    return if performed?

    if error
      @files = stored_files
      flash.now[:alert] = error
      render :upload, status: :unprocessable_content
    else
      redirect_to rnaseq_configure_path
    end
  end

  def configure
    saved = saved_configuration
    @form = form_values((saved&.deseq2 || {}).merge(saved&.clustering || {}).merge(saved&.gp_test || {}))
  end

  def save_configuration
    @form = form_values(configuration_params.to_h)
    deseq2, error = build_settings(@form)
    clustering, error = clustering_settings(@form) unless error
    gp_test, error = gp_test_settings(@form) unless error
    unless error
      begin
        configuration = RnaSeq::Configuration.new(
          counts_file: stored_files["counts_file"], metadata_file: stored_files["metadata_file"],
          annotation_file: stored_files["annotations_file"],
          original_filenames: stored_files["original"], deseq2: deseq2, clustering: clustering, gp_test: gp_test
        )
        session[:rnaseq_config] = configuration.to_h
      rescue RnaSeq::Configuration::Invalid => e
        error = e.message
      end
    end

    if error
      flash.now[:alert] = error
      render :configure, status: :unprocessable_content
    else
      redirect_to rnaseq_review_path
    end
  end

  def review
    @configuration = saved_configuration
    return redirect_to(rnaseq_configure_path, alert: "Please choose the conditions to compare.") unless @configuration

    settings = RnaSeq::Configuration::DISPLAY_DEFAULTS.merge(@configuration.deseq2)
    @settings = settings
    @groups =
      case @configuration.experiment_type
      when "two_condition"
        @inputs.levels(settings["condition_column"]).slice(settings["reference_level"], settings["test_level"])
          .transform_keys { |level| level == settings["reference_level"] ? "#{level} (reference)" : level }
      when RnaSeq::Configuration::GP_TYPE
        gp_groups(settings, @configuration.treatment_start)
      when "condition_by_time"
        @inputs.group_counts([settings["condition_column"], settings["time_column"]],
                             settings["condition_column"] => [settings["reference_level"], settings["test_level"]])
          .sort_by { |(level, _time), _count| level == settings["reference_level"] ? 0 : 1 }
          .to_h.transform_keys { |level, time| "#{level} at time #{time}" }
      else
        filter = settings["subset_level"].present? ? { settings["condition_column"] => [settings["subset_level"]] } : {}
        @inputs.group_counts([settings["time_column"]], filter).transform_keys { |(time)| "time #{time}" }
      end
    @advanced = RnaSeq::Configuration::ADVANCED_DEFAULTS.merge(settings.slice(*RnaSeq::Configuration::ADVANCED_DEFAULTS.keys))
    @pooled_condition = pooled_condition(@configuration.deseq2)
  end

  def submit
    configuration = saved_configuration
    return redirect_to(rnaseq_configure_path, alert: "Please choose the conditions to compare.") unless configuration

    @job, created = JobSubmission.call(user: @user, workspace: @workspace, choices: configuration, analysis_type: "rnaseq")
    session[:current_user_id] = @job.id
    if created
      Rails.logger.info("RnaSeqController#submit submitted job_id=#{@job.id}")
      @job.sendconfirm
      @job.sendadmin
    end
    redirect_to "/generate"
  rescue JobSubmission::InvalidUploads
    redirect_to rnaseq_upload_path, alert: "Please upload a count matrix and a sample sheet before submitting."
  rescue JobSubmission::LimitReached
    redirect_to root_path, alert: "You already have #{Job::MAX_ACTIVE_JOBS_PER_USER} jobs queued or running. Please wait for one to finish."
  rescue UploadWorkspace::Expired
    upload_workspace_expired
  end

  def example
    name = EXAMPLE_FILES.find { |file| file == params[:file_name] }
    return head(:not_found) unless name

    send_file Rails.root.join("lib", "examplefiles", "rnaseq", name), filename: "example_#{name}", type: "text/tab-separated-values"
  end

  private

  # A time course of all samples whose condition column varies within time
  # points but is not a covariate: the conditions' differences count as noise.
  # Returns { "column", "levels" } for the review page's warning, or nil.
  def pooled_condition(deseq2)
    return unless deseq2["experiment_type"] == "time_course" && deseq2["subset_level"].blank?

    column = deseq2["condition_column"]
    time_column = deseq2["time_column"]
    return if column.blank? || Array(deseq2["covariates"]).include?(column)
    return unless @inputs.varies_within?(column, time_column)

    { "column" => column, "levels" => @inputs.levels(column).keys }
  end

  def rnaseq_steps
    [["Upload Files", rnaseq_upload_path], ["Choose Comparison", rnaseq_configure_path],
     ["Review", rnaseq_review_path], ["Submit", nil]]
  end

  def require_rnaseq_session
    return if session[:analysis_type] == "rnaseq"

    redirect_to root_path, alert: "Please choose RNA-seq on the home page to start an RNA-seq analysis."
  end

  # Files saved so far: { "counts_file", "metadata_file", optional "annotations_file",
  # "original" => { "counts", "metadata"[, "annotations"] } }.
  def stored_files
    files = (session[:rnaseq_files] || {}).to_h.deep_stringify_keys
    files["original"] ||= {}
    files
  end

  def input_dir
    @workspace.rnaseq_input_dir
  end

  def inputs_saved?(files = stored_files)
    REQUIRED_KINDS.all? { |kind| file_saved?(files["#{kind}_file"]) } &&
      (files["annotations_file"].blank? || file_saved?(files["annotations_file"]))
  end

  def file_saved?(name)
    name.present? && name == File.basename(name) && input_dir.join(name).file?
  end

  def annotations_path(files)
    files["annotations_file"].present? ? input_dir.join(files["annotations_file"]) : nil
  end

  def load_inputs
    unless inputs_saved?
      redirect_to rnaseq_upload_path, alert: "Please upload a count matrix and a sample sheet first."
      return
    end
    @files = stored_files
    @inputs = RnaSeq::Inputs.new(input_dir.join(@files["counts_file"]), input_dir.join(@files["metadata_file"]),
                                 annotations_path(@files))
  rescue RnaSeq::Inputs::Invalid => e
    redirect_to rnaseq_upload_path, alert: e.message
  end

  # Stages new uploads, checks them together with any file already saved, and
  # only then replaces the saved files, so a bad upload never loses a good one.
  # The annotation table is optional and can be removed. Changing only the
  # annotation table keeps the chosen comparison. Returns an error message, or
  # nil on success.
  def save_uploads
    files = stored_files
    uploads = FILE_KINDS.keys.index_with { |kind| params["#{kind}_file"] }.select { |_kind, file| file.respond_to?(:original_filename) }
    remove_annotations = params[:remove_annotations] == "1" && !uploads.key?("annotations") && files["annotations_file"].present?
    if uploads.empty? && !remove_annotations
      return inputs_saved?(files) ? nil : "Please choose a count matrix and a sample sheet to upload."
    end

    FileUtils.mkdir_p(input_dir)
    staged = {}
    uploads.each do |kind, file|
      extension = File.extname(file.original_filename.to_s).downcase
      unless RnaSeq::Configuration::INPUT_EXTENSIONS.include?(extension)
        return "The #{FILE_KINDS[kind]} must be a .tsv, .txt or .csv file."
      end

      staged[kind] = input_dir.join("incoming-#{kind}#{extension}")
      FileUtils.cp(file.path, staged[kind])
    end

    paths = REQUIRED_KINDS.index_with { |kind| staged[kind] || (files["#{kind}_file"].present? && input_dir.join(files["#{kind}_file"])) }
    missing = paths.select { |_kind, path| !path || !path.file? }.keys
    return "Please also upload a #{missing.map { |kind| FILE_KINDS[kind] }.join(' and ')}." if missing.any?

    annotations = staged["annotations"] || (remove_annotations ? nil : annotations_path(files))
    begin
      RnaSeq::Inputs.new(paths["counts"], paths["metadata"], annotations)
    rescue RnaSeq::Inputs::Invalid => e
      return e.message
    end

    if remove_annotations
      FileUtils.rm_f(input_dir.join(files.delete("annotations_file")))
      files["original"].delete("annotations")
    end
    staged.each do |kind, path|
      FileUtils.rm_f(input_dir.join(files["#{kind}_file"])) if files["#{kind}_file"].present?
      final = "#{kind}#{path.extname}"
      FileUtils.mv(path, input_dir.join(final))
      files["#{kind}_file"] = final
      files["original"][kind] = File.basename(uploads[kind].original_filename.to_s)
    end
    session[:rnaseq_files] = files
    if (staged.keys - ["annotations"]).empty? && session[:rnaseq_config].present?
      config = session[:rnaseq_config].to_h.deep_stringify_keys
      config["annotation_file"] = files["annotations_file"]
      config["original_filenames"] = files["original"]
      session[:rnaseq_config] = config.compact
    else
      session.delete(:rnaseq_config)
    end
    nil
  ensure
    staged&.each_value { |path| FileUtils.rm_f(path) }
  end

  def saved_configuration
    return unless session[:rnaseq_config].present? && inputs_saved?

    configuration = RnaSeq::Configuration.from_h(session[:rnaseq_config])
    files = stored_files
    configuration if configuration.counts_file == files["counts_file"] && configuration.metadata_file == files["metadata_file"] &&
                     configuration.annotation_file == files["annotations_file"].presence
  rescue RnaSeq::Configuration::Invalid
    nil
  end

  def configuration_params
    params.permit(:experiment_type, :condition_column, :reference_level, :test_level, :time_column, :subset_level,
                  :alpha, :lfc_threshold, :lfc_test, :samples_in_model, :cluster_genes, :clusters, :silhouette_baseline,
                  :treatment_timing, :treatment_start, :variable_percent, :permutations, :sampling_design, :replicate_column,
                  covariates: [])
  end

  # Values to show on the form: the user's choices on top of the defaults.
  def form_values(values)
    values = values.to_h.stringify_keys
    defaults = RnaSeq::Configuration::ADVANCED_DEFAULTS
    columns = @inputs.condition_columns
    condition = values["condition_column"].presence || (columns.include?("condition") ? "condition" : columns.first)
    time = values["time_column"].presence || (columns.include?("time") ? "time" : (columns - [condition]).first || condition)
    # Show the advanced section open whenever it holds a non-default choice.
    @advanced_open = defaults.except("covariates").any? { |key, default| values.key?(key) && values[key].to_s != default.to_s && number(values[key]) != default } ||
      Array(values["covariates"]).compact_blank.any?
    {
      "experiment_type" => values["experiment_type"].presence || "two_condition",
      "condition_column" => condition,
      "reference_level" => values["reference_level"].to_s,
      "test_level" => values["test_level"].to_s,
      "time_column" => time,
      "subset_level" => values["subset_level"].to_s,
      "alpha" => values.fetch("alpha", defaults["alpha"]).to_s,
      "lfc_threshold" => values.fetch("lfc_threshold", defaults["lfc_threshold"]).to_s,
      "lfc_test" => values["lfc_test"].presence || defaults["lfc_test"],
      "samples_in_model" => values["samples_in_model"].presence || defaults["samples_in_model"],
      "covariates" => Array(values["covariates"]).compact_blank,
      # Clustering is on unless turned off: "0" from the form, false from a saved configuration.
      "cluster_genes" => values["cluster_genes"].to_s.in?(%w[0 false]) ? "0" : "1",
      "clusters" => values["clusters"].to_s,
      # "1" from the form, true from a saved configuration.
      "silhouette_baseline" => values["silhouette_baseline"].to_s.in?(%w[1 true]) ? "1" : "",
      # Gaussian process comparison. A saved treatment time means it was added partway through.
      "treatment_timing" => values["treatment_timing"].presence || (values["treatment_start"].present? ? "added" : "start"),
      "treatment_start" => display_number(values["treatment_start"]),
      "variable_percent" => display_number(values["variable_percent"]),
      "permutations" => values["permutations"].to_s,
      # Never pre-selected: only the user knows how the samples were collected.
      "sampling_design" => values["sampling_design"].to_s,
      "replicate_column" => values["replicate_column"].to_s
    }
  end

  def display_number(value)
    value.is_a?(Float) && value == value.to_i ? value.to_i.to_s : value.to_s
  end

  # Returns [deseq2 settings, error message]. The R script repeats every check.
  def build_settings(form)
    type = form["experiment_type"]
    return [nil, "Please choose a type of analysis."] unless RnaSeq::Configuration::EXPERIMENT_TYPES.key?(type)

    time_type = RnaSeq::Configuration::TIME_TYPES.include?(type)
    uses_condition = type != "time_course" || form["subset_level"].present?
    settings = {}
    settings["experiment_type"] = type unless type == "two_condition"
    used = []

    if uses_condition
      column = form["condition_column"]
      return [nil, "Please choose the sample sheet column that holds the conditions."] unless @inputs.condition_columns.include?(column)

      settings["condition_column"] = column
      used << column
    end

    if time_type
      time_column = form["time_column"]
      return [nil, "Please choose the sample sheet column that holds the time points."] unless @inputs.condition_columns.include?(time_column)
      return [nil, "The time column must be different from the condition column."] if used.include?(time_column)
      return [nil, "The time column \"#{time_column}\" needs at least two different time points."] if @inputs.levels(time_column).length < 2

      settings["time_column"] = time_column
      used << time_column
    end


    error =
      case type
      when "two_condition" then two_condition_settings(form, settings)
      when "condition_by_time" then condition_by_time_settings(form, settings)
      when RnaSeq::Configuration::GP_TYPE then condition_time_gp_settings(form, settings, used)
      else time_course_settings(form, settings)
      end
    return [nil, error] if error

    # A time course of all samples does not model the condition column, but
    # keep it so the review page can warn when conditions are pooled. The R
    # script ignores it without subset_level. Recorded only now, because
    # time_course_settings reads a condition column as a chosen subset.
    if !uses_condition && @inputs.condition_columns.include?(form["condition_column"]) && !used.include?(form["condition_column"])
      settings["condition_column"] = form["condition_column"]
    end

    advanced_settings(form, settings, used, time_type)
  end

  def two_condition_settings(form, settings)
    levels = @inputs.levels(settings["condition_column"])
    reference, test = form.values_at("reference_level", "test_level")
    error = comparison_error(levels, reference, test)
    return error if error

    small = [reference, test].select { |level| levels[level] < RnaSeq::Inputs::MIN_REPLICATES }
    if small.any?
      return "Each compared condition needs at least #{RnaSeq::Inputs::MIN_REPLICATES} replicate samples. " \
             "#{small.map { |level| "\"#{level}\" has #{levels[level]}" }.join(' and ')}."
    end

    settings.merge!("reference_level" => reference, "test_level" => test)
    nil
  end

  def condition_by_time_settings(form, settings)
    column, time_column = settings.values_at("condition_column", "time_column")
    reference, test = form.values_at("reference_level", "test_level")
    error = comparison_error(@inputs.levels(column), reference, test)
    return error if error

    counts = @inputs.group_counts([column, time_column], column => [reference, test])
    cells = [reference, test].product(@inputs.levels(time_column).keys).map { |cell| [cell, counts.fetch(cell, 0)] }
    present_times = cells.select { |_cell, count| count.positive? }.map { |(_level, time), _count| time }.uniq
    cells.select! { |(_level, time), _count| present_times.include?(time) }
    error = replicate_error(cells.to_h.transform_keys { |level, time| "#{level} at time #{time}" },
                            "condition and time point combination")
    return error if error
    return "The two conditions need at least two time points in common." if present_times.length < 2

    settings.merge!("reference_level" => reference, "test_level" => test)
    nil
  end

  # The Gaussian process comparison: two conditions, numeric times, the
  # treatment timing and how the samples were collected. The R and Python
  # scripts repeat these checks.
  def condition_time_gp_settings(form, settings, used)
    column, time_column = settings.values_at("condition_column", "time_column")
    reference, test = form.values_at("reference_level", "test_level")
    error = comparison_error(@inputs.levels(column), reference, test)
    return error if error

    filter = { column => [reference, test] }
    times = numeric_times(time_column, filter)
    return "The time column \"#{time_column}\" must hold numbers, such as 0, 6 and 24, so curves can be fitted over time." unless times
    return "This comparison needs at least 3 different time points; \"#{time_column}\" has #{times.length}." if times.length < 3

    start, error = treatment_start_value(form, times)
    return error if error

    error = replicate_error(gp_cells(column, time_column, reference, test, times, start), "group")
    return error if error

    error = sampling_settings(form, settings, used, column, time_column, reference, test)
    return error if error

    settings.merge!("reference_level" => reference, "test_level" => test)
    nil
  end

  # [[number, label]] of the time points among the chosen samples, in order, or nil if any is not a number.
  def numeric_times(time_column, filter)
    labels = @inputs.group_counts([time_column], filter).keys.map(&:first)
    values = labels.map { |label| number(label) }
    return if values.any?(&:nil?)

    values.zip(labels).sort_by(&:first)
  end

  # Returns [treatment time or nil (treated from the start), error message].
  def treatment_start_value(form, times)
    return [nil, nil] unless form["treatment_timing"] == "added"

    start = number(form["treatment_start"])
    first, last = times.first.first, times.last.first
    return [nil, "Please enter the time the treatment was added, as a number."] unless start
    unless start >= first && start < last
      return [nil, "The treatment time must be at or after the first time point (#{display_number(first)}) " \
                   "and before the last (#{display_number(last)}), so some samples were taken after it."]
    end
    [start, nil]
  end

  # { group name => samples }: each condition at each time after the treatment,
  # and both conditions together at the shared times up to it.
  def gp_cells(column, time_column, reference, test, times, start)
    counts = @inputs.group_counts([column, time_column], column => [reference, test])
    times.each_with_object({}) do |(value, label), cells|
      if start && value <= start
        cells["time #{label} (before the treatment)"] = counts.fetch([reference, label], 0) + counts.fetch([test, label], 0)
      else
        [reference, test].each { |level| cells["#{level} at time #{label}"] = counts.fetch([level, label], 0) }
      end
    end
  end

  def sampling_settings(form, settings, used, column, time_column, reference, test)
    design = form["sampling_design"]
    unless RnaSeq::Configuration::SAMPLING_DESIGNS.key?(design)
      return "Please say how the samples were collected: as separate cultures, or by sampling each culture repeatedly."
    end

    settings["sampling_design"] = design
    return if design == "independent"

    culture = form["replicate_column"]
    return "Please choose the sample sheet column that names each culture." unless @inputs.condition_columns.include?(culture)
    return "The culture column must be different from the condition and time columns." if used.include?(culture)

    filter = { column => [reference, test] }
    pairs = @inputs.group_counts([culture, column], filter).keys
    mixed = pairs.group_by(&:first).select { |_culture, levels| levels.length > 1 }.keys
    return "Each culture must belong to one condition. These have samples of both: #{mixed.first(6).join(', ')}." if mixed.any?

    twice = @inputs.group_counts([culture, time_column], filter).select { |_key, count| count > 1 }.keys
    if twice.any?
      return "Each culture can have at most one sample per time point. Sampled more than once: " \
             "#{twice.first(6).map { |name, time| "#{name} at time #{time}" }.join(', ')}."
    end

    per_condition = pairs.map(&:last).tally
    small = [reference, test].select { |level| per_condition.fetch(level, 0) < RnaSeq::Inputs::MIN_REPLICATES }
    if small.any?
      return "Each condition needs at least #{RnaSeq::Inputs::MIN_REPLICATES} cultures. " \
             "#{small.map { |level| "\"#{level}\" has #{per_condition.fetch(level, 0)}" }.join(' and ')}."
    end

    settings["replicate_column"] = culture
    used << culture
    nil
  end

  # Samples per group for the review page.
  def gp_groups(settings, start)
    column, time_column = settings.values_at("condition_column", "time_column")
    times = numeric_times(time_column, column => [settings["reference_level"], settings["test_level"]]) || []
    gp_cells(column, time_column, settings["reference_level"], settings["test_level"], times, start)
  end

  # Returns [Gaussian process test settings, error message]; the timing was checked in build_settings.
  def gp_test_settings(form)
    return [nil, nil] unless form["experiment_type"] == RnaSeq::Configuration::GP_TYPE

    settings = {}
    settings["treatment_start"] = number(form["treatment_start"]) if form["treatment_timing"] == "added"
    if form["variable_percent"].present?
      percent = number(form["variable_percent"])
      unless percent&.positive? && percent <= 100
        return [nil, "The percent of most variable genes must be a number more than 0 and at most 100, or blank for automatic."]
      end

      settings["variable_percent"] = percent
    end
    if form["permutations"].present?
      range = RnaSeq::Configuration::PERMUTATION_COUNTS
      count = Integer(form["permutations"].strip, 10, exception: false)
      return [nil, "The number of permutations must be a whole number from #{range.min} to #{range.max}."] unless count && range.cover?(count)

      settings["permutations"] = count unless count == RnaSeq::Configuration::DEFAULT_PERMUTATIONS
    end
    [settings.presence, nil]
  end

  def time_course_settings(form, settings)
    time_column = settings["time_column"]
    filter = {}
    if settings["condition_column"]
      level = form["subset_level"]
      return "Please choose which condition to analyze." unless @inputs.levels(settings["condition_column"]).key?(level)

      filter = { settings["condition_column"] => [level] }
      settings["subset_level"] = level
    end
    cells = @inputs.group_counts([time_column], filter).transform_keys { |(time)| "time #{time}" }
    return "The chosen samples need at least two different time points." if cells.length < 2

    replicate_error(cells, "time point")
  end

  def comparison_error(levels, reference, test)
    return "Please choose a reference condition and a test condition." unless levels.key?(reference) && levels.key?(test)

    "The reference and test conditions must be different." if reference == test
  end

  def replicate_error(cells, description)
    small = cells.select { |_name, count| count < RnaSeq::Inputs::MIN_REPLICATES }
    return if small.empty?

    "Each #{description} needs at least #{RnaSeq::Inputs::MIN_REPLICATES} replicate samples. " \
      "Too few in: #{small.first(6).map { |name, count| "#{name} (#{count})" }.join(', ')}."
  end

  # Returns [settings, error message].
  def advanced_settings(form, settings, used, time_type)
    alpha = number(form["alpha"])
    return [nil, "The significance level must be a number between 0 and 1, such as 0.05."] unless alpha && alpha.positive? && alpha < 1

    lfc = number(form["lfc_threshold"])
    return [nil, "The log2 fold-change cutoff must be a number of 0 or more."] unless lfc && lfc >= 0
    return [nil, "Please choose how to apply the fold-change cutoff."] unless RnaSeq::Configuration::LFC_TESTS.key?(form["lfc_test"])
    if time_type && form["lfc_test"] == "deseq2" && lfc.positive?
      return [nil, "For a time course, the fold-change cutoff can only be applied after testing."]
    end
    return [nil, "Please choose which samples to include in the model."] unless RnaSeq::Configuration::SAMPLES_IN_MODEL.key?(form["samples_in_model"])

    covariates = form["covariates"].uniq
    invalid = covariates - (@inputs.condition_columns - used)
    return [nil, "Covariates must be other columns of the sample sheet, not the condition or time column."] if invalid.any?

    constant = covariates.select { |covariate| @inputs.levels(covariate).length < 2 }
    return [nil, "A covariate needs at least two different values. #{constant.map(&:inspect).join(', ')} has only one."] if constant.any?

    defaults = RnaSeq::Configuration::ADVANCED_DEFAULTS
    settings["alpha"] = alpha unless alpha == defaults["alpha"]
    settings["lfc_threshold"] = lfc unless lfc == defaults["lfc_threshold"]
    settings["lfc_test"] = form["lfc_test"] unless form["lfc_test"] == defaults["lfc_test"] || time_type
    # Time-course designs choose their samples themselves.
    settings["samples_in_model"] = form["samples_in_model"] unless form["samples_in_model"] == defaults["samples_in_model"] || time_type
    settings["covariates"] = covariates if covariates.any?
    [settings, nil]
  end

  # Returns [clustering settings, error message]. A blank cluster count means choose it from the data.
  def clustering_settings(form)
    return [nil, nil] unless RnaSeq::Configuration::TIME_TYPES.include?(form["experiment_type"])
    # The Gaussian process comparison tests the clusters, so clustering is always on there.
    gp = form["experiment_type"] == RnaSeq::Configuration::GP_TYPE
    return [{ "cluster_genes" => false }, nil] if form["cluster_genes"] == "0" && !gp

    settings = {}
    if form["clusters"].present?
      range = RnaSeq::Configuration::CLUSTER_COUNTS
      count = Integer(form["clusters"].strip, 10, exception: false)
      return [nil, "The number of gene clusters must be a whole number from #{range.min} to #{range.max}, or Automatic."] unless count && range.cover?(count)

      settings["clusters"] = count
    end
    settings["silhouette_baseline"] = true if form["silhouette_baseline"] == "1"
    [settings.presence, nil]
  end

  def number(value)
    Float(value.to_s.strip)
  rescue ArgumentError
    nil
  end
end
