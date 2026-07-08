#!/usr/bin/env ruby
# require 'logger'
# LOGGER = Logger.new( 'log/log.txt', 'daily' )


class Job < ApplicationRecord
  belongs_to :user
  attr_accessor :title

  def upload_root
    Rails.root.join("private", "uploads", "jobs", id.to_s)
  end

  def data_dir = upload_root.join("data")
  def mapping_dir = upload_root.join("mapping")
  def summary_dir = upload_root.join("summary")
  def derived_dir = upload_root.join("derived")
  def models_dir = upload_root.join("models")
  def figures_dir = upload_root.join("figures")
  def parameters_dir = upload_root.join("parameters")
  def ensure_upload_directories!
    [data_dir, mapping_dir, parameters_dir, figures_dir, summary_dir, derived_dir, models_dir].each { |d| FileUtils.mkdir_p(d) }
  end
  def clear_uploads!
    FileUtils.rm_rf(upload_root)
  end

  # Configuration constants
  MAX_ACTIVE_JOBS_PER_USER = 3
  DRAFT_STATUS = "In Progress".freeze

  def upload_root
    Rails.root.join("private", "uploads", "jobs", id.to_s)
  end

  def data_dir = upload_root.join("data")
  def mapping_dir = upload_root.join("mapping")
  def summary_dir = upload_root.join("summary")
  def derived_dir = upload_root.join("derived")
  def models_dir = upload_root.join("models")
  def figures_dir = upload_root.join("figures")
  def parameters_dir = upload_root.join("parameters")

  def ensure_upload_directories!
    [data_dir, mapping_dir, parameters_dir, figures_dir, summary_dir, derived_dir, models_dir].each { |d| FileUtils.mkdir_p(d) }
  end

  def clear_uploads!
    FileUtils.rm_rf(upload_root)
  end

  # Keep only the most recent draft for a user, destroying any older
  # "In Progress" jobs. Returns the surviving draft (or nil).
  def self.prune_drafts(user_id)
    drafts = where(user_id: user_id, status: DRAFT_STATUS).order(created_at: :desc).to_a
    drafts.drop(1).each(&:destroy)
    drafts.first
  end

  def deleteoldfiles
    FileUtils.rm_rf(figures_dir)
    FileUtils.rm_rf(summary_dir)
  end

  DEFAULT_TSS = 1
  USER_SELECTABLE_TSS_MAX = 15
  HIGH_IMPACT_TSS_THRESHOLD = 10
  TSS_RETRY_INCREMENT = 2
  MAX_TSS_ATTEMPTS = 4
  MIN_GP_TIME_POINTS = 8
  MEMORY_FAILURE_EXIT_CODES = [137, 139].freeze

  def self.time_point_count_for_data_file(path)
    lines = []

    File.open(path, 'rb') do |file|
      file.each_line do |line|
        lines << line.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').delete_prefix("\uFEFF").chomp
        break if lines.length == 2
      end
    end

    time_header = lines[1].to_s
    return nil if time_header.blank?

    separator = time_header.include?("\t") ? "\t" : ","
    count = time_header.split(separator).drop(1).reject(&:blank?).count
    count.positive? ? count : nil
  rescue => e
    Rails.logger.warn("Unable to count time points for #{path}: #{e.message}")
    nil
  end

  def self.max_safe_tss_for_time_points(total_time_points)
    total_time_points = total_time_points.to_i
    return nil if total_time_points < MIN_GP_TIME_POINTS

    [total_time_points / MIN_GP_TIME_POINTS, DEFAULT_TSS].max
  end

  def normalize_tss(value)
    raw_value = value.to_s.strip
    return DEFAULT_TSS if raw_value.blank?
    return DEFAULT_TSS unless raw_value.match?(/\A[1-9]\d*\z/)

    raw_value.to_i
  end

  def minimum_time_point_count
    counts = Dir.glob(data_dir.join("*.txt")).map do |path|
      self.class.time_point_count_for_data_file(path)
    end.compact

    counts.min
  end

  def max_safe_tss
    self.class.max_safe_tss_for_time_points(minimum_time_point_count)
  end

  def tss_retry_values(starting_tss)
    starting_tss = normalize_tss(starting_tss)

    values = MAX_TSS_ATTEMPTS.times.map do |attempt_index|
      starting_tss + (attempt_index * TSS_RETRY_INCREMENT)
    end

    safe_max = max_safe_tss
    return values if safe_max.nil?

    values.select { |tss| tss <= safe_max }
  end

  def record_used_tss(analysis_name, requested_tss, used_tss)
    requested_tss = normalize_tss(requested_tss)

    @used_tss[analysis_name] = {
      requested: requested_tss,
      used: used_tss,
      retried: used_tss != requested_tss,
      high_impact: used_tss > HIGH_IMPACT_TSS_THRESHOLD
    }
  end

  def run_with_tss_retry(base_command, analysis_name, starting_tss = DEFAULT_TSS)
    tss_retry_values(starting_tss).each do |tss|
      command = base_command.dup
      command += " -tss #{tss}" unless tss == DEFAULT_TSS
      @last_tss_attempts ||= {}
      @last_tss_attempts[analysis_name] = tss

      logger.info("[#{analysis_name}] Running: #{command}")
      system(command)

      if $?.success?
        record_used_tss(analysis_name, starting_tss, tss)
        return true
      end

      break unless MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
    end

    false
  end

  def memory_failure_message(analysis_name)
    "#{analysis_name} could not be completed because it exceeded the available computational memory. " \
    "MicroNet automatically retried the analysis using larger Gaussian Process time step sizes to reduce memory usage, but the analysis still could not be completed.\n\n" \
    "Recommendations:\n" \
    "• Analyze a smaller subset of your data.\n" \
    "• Reduce the number of samples or pooled conditions, if applicable.\n" \
    "• Run the analysis on a system with additional computational memory."
  end

  def analyze(chart_types, pool_replicates, pool_options_string, test_finalsubset, hypothesis, gp_pool_by_column, gp_subset_choice, gp_finalsubset, compare_parameters_pool, compare_finalsubset, heatmap_value, heatmap_x, heatmap_y, gp_time_step_size = DEFAULT_TSS)
    @used_tss = {}
    @last_tss_attempts = {}
    @requested_tss = normalize_tss(gp_time_step_size)
    safe_max_tss = max_safe_tss
    if safe_max_tss.present? && @requested_tss > safe_max_tss
      raise "The selected Gaussian Process time step size is too large for this dataset. Please choose #{safe_max_tss} or lower so the model has at least #{MIN_GP_TIME_POINTS} time points to fit."
    end

    self.status = "Analyzing..."
    self.start_time = DateTime.now

    # ADD THESE 4 LINES HERE
    FileUtils.mkdir_p(summary_dir)
    FileUtils.mkdir_p(derived_dir)
    FileUtils.mkdir_p(models_dir)
    FileUtils.mkdir_p(figures_dir)
    
    @selected_chart_types = chart_types || []
    @pool_replicates = pool_replicates
    @pool_options_string = pool_options_string || []
    @test_finalsubset = test_finalsubset
    @hypothesis = hypothesis
    @compare_parameters_pool = compare_parameters_pool
    @compare_finalsubset = compare_finalsubset
    @gp_pool_by_column = gp_pool_by_column
    @gp_subset_choice = gp_subset_choice
    @gp_finalsubset = gp_finalsubset
    @heatmap_value = heatmap_value
    @heatmap_x = heatmap_x
    @heatmap_y = heatmap_y

    raw_data_results = nil
    fit_summary_path = nil
    fit_stats_path = nil
    compare_params_paths = nil
    test_hypothesis_paths = nil
    test_hypothesis_pdf_paths = nil
    compare_params_pdf_paths = nil
    gp_plot_path = nil
    gp_plot_data = nil
    heatmap_plot_paths = nil

    begin

      logger.debug("Starting analysis...")
      raw_data_results = RawDataGenerator.generate_raw_data(upload_root)
      if @selected_chart_types.include?('raw_data')
        unless raw_data_results[:raw_data_pdf_paths].present?
          raise "Your dataset is too large for the Raw Data plot analysis. Please try uploading a smaller dataset." if $?.exitstatus == 137
          raise "The plotting analysis failed. Please check your input and data files." if $?.exitstatus != 0
        end
        @raw_data_pdf_paths = raw_data_results[:raw_data_pdf_paths].select do |path|
          File.exist?(path)
        end
      end
      logger.debug("done with raw_data ...")

      if @selected_chart_types.include?('gp_plot')
        pool_by_clean = gp_pool_by_column.to_s.gsub(/\A'|'\z/, '').strip
        pool_by_flag = pool_by_clean.present? && pool_by_clean != "None" ? "--pool-by '#{pool_by_clean}'" : ""
        if @gp_subset_choice == "yes"
          unless run_with_tss_retry("amiga fit -i #{upload_root} -s #{gp_finalsubset} #{pool_by_flag} --save-gp-data -o plot","Gaussian Process Plot", @requested_tss)
            raise memory_failure_message("The Gaussian Process Plot analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
            raise "The Gaussian Process Plot analysis failed. Please check that your input data or selected conditions are correct."
          end
        else
          unless run_with_tss_retry("amiga fit -i #{upload_root} #{pool_by_flag} --save-gp-data -o plot","Gaussian Process Plot", @requested_tss)
            raise memory_failure_message("The Gaussian Process Plot analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
            raise "The Gaussian Process Plot analysis failed. Please check that your input data or selected conditions are correct."
          end
        end
        raise memory_failure_message("The Gaussian Process Plot analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
        Python.exec("lib/scripts/otherscripts/gpplot.py #{derived_dir} #{gp_finalsubset}")
        gp_plot_path = derived_dir.join('gp_plot.pdf')
        gp_plot_data = derived_dir.join('plot_gp_data.txt')
        raise "The GP plot analysis failed" unless File.exist?(gp_plot_path) && File.exist?(gp_plot_data)
        @gp_plot_path = Dir.glob(derived_dir.join('gp_plot.pdf'))
        @gp_plot_data = Dir.glob(derived_dir.join('plot_gp_data.txt'))
        logger.debug("done with gp_plot ...")
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "no"
        unless run_with_tss_retry("amiga fit -i #{upload_root} -o fit", "Fit Statistics", @requested_tss)
          raise memory_failure_message("The Fit Statistics analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
          raise "The Fit Statistics analysis failed."
        end
        fit_summary_path = summary_dir.join('fit_summary_modified.txt')
        raise memory_failure_message("The Fit Statistics analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
        Python.exec("lib/scripts/otherscripts/simplifyfit.py #{summary_dir.join('fit_summary.txt')}")
        raise "The fit statistics analysis failed" unless File.exist?(fit_summary_path)
        @fit_stats_paths = Dir.glob(summary_dir.join('fit_summary_modified.txt'))
        logger.debug("done with fit_stats yes ...")
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes"
        unless run_with_tss_retry("amiga fit -i #{upload_root} --pool-by '#{pool_options_string}' -o fit", "Fit Statistics", @requested_tss)
          raise "Your dataset is too large for the fit statistics analysis. Please try uploading a smaller dataset." if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
        end
        puts "AMIGA EXIT STATUS = #{$?.exitstatus}"
        puts "fit_summary exists? #{File.exist?(summary_dir.join('fit_summary.txt'))}"
        puts Dir.glob(summary_dir.join('*'))
        Python.exec("lib/scripts/otherscripts/simplifyfit.py #{summary_dir.join('fit_summary.txt')}")
        fit_stats_path = summary_dir.join('fit_summary_modified.txt')
        raise "The fit statistics (pooling requested) analysis failed" if not File.exist?(fit_stats_path)
        @fit_stats_paths = Dir.glob(summary_dir.join('fit_summary_modified.txt'))
        logger.debug("done with fit_stats no ...")
      end

      if @selected_chart_types.include?('heatmap_plot')
        if @heatmap_value.present? && @heatmap_x.present? && @heatmap_y.present?
          if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes" && fit_stats_path.present?
            heatmap_x = @heatmap_x == "Well positions" ? "Well" : @heatmap_x
            heatmap_y = @heatmap_y == "Well positions" ? "Well" : @heatmap_y
            puts "HEATMAP VALUE = #{@heatmap_value}"
            puts "HEATMAP X = #{@heatmap_x}"
            puts "HEATMAP Y = #{@heatmap_y}"
            system("amiga fit -i #{upload_root} -o heatmap_fit")
            raise "Your dataset is too large for the heatmap analysis. Please try uploading a smaller dataset or selecting a different variable." if $?.exitstatus == 137
            Python.exec("lib/scripts/otherscripts/simplifyfit.py #{summary_dir.join('heatmap_fit_summary.txt')}")
            heatmap_fit_summary_path = summary_dir.join('heatmap_fit_summary_modified.txt')
            raise "The heatmap analysis failed. Please check your axis/value selections." unless File.exist?(heatmap_fit_summary_path)
            system("amiga heatmap -i #{heatmap_fit_summary_path} -o heatmap_plot -x \"#{heatmap_x}\" -y \"#{heatmap_y}\" -v \"#{heatmap_value}\" --title 'Heatmap: #{heatmap_value}' --keep-columns-missing-data --keep-rows-missing-data --kwargs 'cmap:Reds' --x-tick-labels-scale 1 --y-tick-labels-scale 1 --color-bar-labels-scale 0.6")
          else
            heatmap_x = @heatmap_x == "Well positions" ? "Well" : @heatmap_x
            heatmap_y = @heatmap_y == "Well positions" ? "Well" : @heatmap_y
            puts "HEATMAP VALUE = #{@heatmap_value.inspect}"
            puts "HEATMAP X = #{@heatmap_x.inspect}"
            puts "HEATMAP Y = #{@heatmap_y.inspect}"
            system("amiga fit -i #{upload_root} -o fit")
            raise "Your dataset is too large for the heatmap analysis. Please try a smaller dataset or selecting a different variable." if $?.exitstatus == 137
            Python.exec("lib/scripts/otherscripts/simplifyfit.py #{summary_dir.join('fit_summary.txt')}")
            heatmap_fit_summary_path = summary_dir.join('fit_summary_modified.txt')
            raise "The heatmap analysis failed. Please check your axis/value selections." unless File.exist?(heatmap_fit_summary_path)
            system("amiga heatmap -i #{summary_dir.join('fit_summary_modified.txt')} -o heatmap_plot -x \"#{heatmap_x}\" -y \"#{heatmap_y}\" -v \"#{heatmap_value}\" --title 'Heatmap: #{heatmap_value}' --keep-columns-missing-data --keep-rows-missing-data --kwargs 'cmap:Reds' --x-tick-labels-scale 1 --y-tick-labels-scale 1 --color-bar-labels-scale 0.6")
          end
        else
          raise "Heatmap value, x-axis, or y-axis not selected"
        end
        heatmap_plot_path = summary_dir.join('heatmap_plot.pdf')
        unless File.exist?(heatmap_plot_path)
          raise "Your dataset is too large for the heatmap analysis. Please try a smaller datasetor selecting a different variable." if $?.exitstatus == 137
          raise "The heatmap plot analysis failed. Please check your axis/value selections." 
        end
        @heatmap_plot_paths = Dir.glob(summary_dir.join('heatmap_plot.pdf'))
        logger.debug("done with heatmap_plot ...")
      end

      if @selected_chart_types.include?('compare-parameters')
        FileUtils.rm_rf(models_dir.join('compare-parameters.txt'))
        #ensures the previous job files are removed before calling amiga 
        unless run_with_tss_retry("amiga fit -i #{upload_root} --sample-posterior --pool-by #{compare_parameters_pool} -o compare","Compare Parameters", @requested_tss)
          raise memory_failure_message("The Compare Parameters analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
          raise "The Compare Parameters analysis failed. Please check that your input data or selected conditions are correct."
        end
        puts "AMIGA EXIT STATUS = #{$?.inspect}"
        unless File.exist?(summary_dir.join('compare_summary.txt'))
          raise "Your dataset is too large for the compare parameters analysis. Please try uploading a smaller dataset or selecting a different variable." if $?.exitstatus == 137 || $?.signaled?
          raise "The compare parameters analysis failed. Please check that your input data or selected conditions are correct."
        end
        system("amiga compare -i #{summary_dir.join('compare_summary.txt')} -o compare-parameters -s #{compare_finalsubset} --verbose")
        old_path = "compare-parameters.txt"
        new_path = models_dir.join("compare-parameters.txt")
        File.rename(old_path, new_path) if File.exist?(old_path)
        fit_stats_sample_paths = Dir.glob(summary_dir.join('compare_summary.txt'))
        compare_params_txts = Dir.glob(models_dir.join('*.txt'))
        logger.debug("compare_params_txts: #{compare_params_txts}")
        if compare_params_txts.empty? && fit_stats_sample_paths.empty?
          raise memory_failure_message("The Compare Parameters analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
          raise "The compare parameters analysis failed. Please check that your input data or selected conditions are correct."
        end
        @compare_params_paths = compare_params_txts
        logger.debug("done with compare-parameters ...")
      end
      save # Save the instance of Job

      if @selected_chart_types.include?('test-hypothesis')
        FileUtils.rm_rf(models_dir.join('test-hypothesis'))
        #ensures the previous job files are removed before calling amiga 
        unless run_with_tss_retry("amiga test -i #{upload_root} -s #{test_finalsubset} -y #{hypothesis} -o 'test-hypothesis'","Test Hypothesis", @requested_tss)
          if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
            raise memory_failure_message("The Test Hypothesis analysis")
          
          end
        end
        test_hypothesis_txts = Dir.glob(models_dir.join('test-hypothesis', '*report.txt'))
        test_hypothesis_pdfs = Dir.glob(models_dir.join('test-hypothesis', '*.pdf'))
        if test_hypothesis_txts.empty? && test_hypothesis_pdfs.empty?
          raise memory_failure_message("The Test Hypothesis analysis") if MEMORY_FAILURE_EXIT_CODES.include?($?.exitstatus) || $?.signaled?
          raise "The test hypothesis failed. Please check that your input data or selected conditions are correct." 
        end
        unless @used_tss["Test Hypothesis"].present?
          final_tss = @last_tss_attempts["Test Hypothesis"] || @requested_tss
          record_used_tss("Test Hypothesis", @requested_tss, final_tss)
          logger.warn("[Test Hypothesis] AMIGA exited non-zero but output files were created; reporting time step size #{final_tss}.")
        end
        @test_hypothesis_paths = test_hypothesis_txts
        @test_hypothesis_pdf_paths = test_hypothesis_pdfs
        logger.debug("done with test-hypothesis ...")
      end
      save # Save the instance of Job

      file_names = []
      file_names += @raw_data_pdf_paths if @raw_data_pdf_paths.present?
      file_names += @fit_stats_paths if @fit_stats_paths.present?
      file_names += @compare_params_paths if @compare_params_paths.present?
      file_names += @test_hypothesis_paths if @test_hypothesis_paths.present?
      file_names += @test_hypothesis_pdf_paths if @test_hypothesis_pdf_paths.present?
      file_names += @compare_params_pdf_paths if @compare_params_pdf_paths.present?
      file_names += @gp_plot_path if @gp_plot_path.present?
      file_names += @gp_plot_data if @gp_plot_data.present?
      file_names += @heatmap_plot_paths if @heatmap_plot_paths.present?

      UserMailer.processedjob_email(file_names, self, @used_tss, @requested_tss).deliver_now
    rescue => e
      logger.error("Error processing job: #{e.message}")
      # Reload from DB to check if job was cancelled while this was running
      self.reload
      # Don't mark as failed if job was cancelled by admin
      if self.status != "Cancelled"
        self.status = "Failed"
        self.end_time = DateTime.now
        save
        UserMailer.failedjob_email(self, e.message).deliver_now
      else
        logger.info("Job #{id} was cancelled by admin, skipping error email")
      end
    ensure
      self.reload
      if self.status == "Analyzing..."
        self.status = "Completed"
        self.end_time = DateTime.now
        save
      end
    end
  end

  def serve_image
    job = Job.find(params[:job_id])
    filename = params[:filename]

    file_path = job.upload_root.join("figures", filename)

    if File.exist?(file_path) && File.file?(file_path)
      send_file file_path, disposition: "inline"
    else
      render plain: "File not found", status: :not_found
    end
  end

  def sendconfirm
    logger.info("Sending confirmation for job id: #{id}")
    UserMailer.with(job: self, user: User.find(self.user_id)).confirm_email.deliver_now
  end

  def sendadmin
    logger.info("Sending admin email for job id: #{id}")
    # UserMailer.with(job: self, user: User.find(self.user_id)).admin_email.deliver_now
  end


  def self.admin_can_manage_jobs?(admin)
    admin&.is_admin?
  end

  def admin_can_manage_jobs?(admin)
    admin&.is_admin?
  end

  # Count active submitted jobs (queued or running only)
  def self.count_active_for_user(user_id)
    where(user_id: user_id, status: ["Job submitted", "Analyzing..."]).count
  end

  # Check if user can submit another job
  def self.can_user_submit?(user_id)
    count_active_for_user(user_id) < MAX_ACTIVE_JOBS_PER_USER
  end

  # Mark job as cancelled without destroying it
  def mark_cancelled(admin_name = nil)
    self.status = "Cancelled"
    self.end_time = DateTime.now
    save
    UserMailer.job_cancelled_email(self, admin_name).deliver_now
  end

  # Set end_time when job finishes
  def set_end_time
    self.end_time = DateTime.now
    save
  end
end
