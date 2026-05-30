#!/usr/bin/env ruby
# require 'logger'
# LOGGER = Logger.new( 'log/log.txt', 'daily' )


class Job < ApplicationRecord
  belongs_to :user
  attr_accessor :title

  # Configuration constants
  MAX_ACTIVE_JOBS_PER_USER = 3


  def analyze(chart_types, pool_replicates, pool_options_string, test_finalsubset, hypothesis, gp_pool_by_column, gp_subset_choice, gp_finalsubset, compare_parameters_pool, compare_finalsubset, heatmap_value, heatmap_x, heatmap_y)
    self.status = "Analyzing..."
    self.start_time = DateTime.now
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
      raw_data_results = RawDataGenerator.generate_raw_data()
      if @selected_chart_types.include?('raw_data')
        raise "The plotting analysis failed" unless raw_data_results[:raw_data_pdf_paths].present?
        @raw_data_pdf_paths = raw_data_results[:raw_data_pdf_paths].select do |path|
          File.exist?(path)
        end
      end
      logger.debug("done with raw_data ...")

      if @selected_chart_types.include?('gp_plot')
        if @gp_subset_choice == "no"
          system("amiga fit -i private/uploads/userexpt --pool-by '#{gp_pool_by_column}' --save-gp-data -o plot")
        elsif @gp_subset_choice == "yes"
          system("amiga fit -i private/uploads/userexpt -s #{gp_finalsubset} --pool-by '#{gp_pool_by_column}' --save-gp-data -o plot")
        else
          raise "Invalid GP subset choice"
        end
        Python.exec("lib/scripts/otherscripts/gpplot.py private/uploads/userexpt/derived #{gp_finalsubset}")
        gp_plot_path = Rails.root.join('private', 'uploads', 'userexpt', 'derived', 'gp_plot.pdf')
        gp_plot_data = Rails.root.join('private', 'uploads', 'userexpt', 'derived', 'plot_gp_data.txt')
        raise "The GP plot analysis failed" unless File.exist?(gp_plot_path) && File.exist?(gp_plot_data)
        @gp_plot_path = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'derived', 'gp_plot.pdf'))
        @gp_plot_data = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'derived', 'plot_gp_data.txt'))
        logger.debug("done with gp_plot ...")
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "no"
        system("amiga fit -i private/uploads/userexpt -o fit")
        fit_summary_path = Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt')
        Python.exec("lib/scripts/otherscripts/simplifyfit.py private/uploads/userexpt/summary/fit_summary.txt")
        raise "The fit statistics analysis failed" unless File.exist?(fit_summary_path)
        @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt'))
        logger.debug("done with fit_stats yes ...")
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes"
        system("amiga fit -i private/uploads/userexpt --pool-by '#{pool_options_string}' -o fit")
        Python.exec("lib/scripts/otherscripts/simplifyfit.py private/uploads/userexpt/summary/fit_summary.txt")
        fit_stats_path = Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt')
        raise "The fit statistics (pooling requested) analysis failed" if not File.exist?(fit_stats_path)
        @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt'))
        logger.debug("done with fit_stats no ...")
      end

      if @selected_chart_types.include?('heatmap_plot')
        if @heatmap_value.present? && @heatmap_x.present? && @heatmap_y.present?
          if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes" && fit_stats_path.present?
            system("amiga heatmap -i private/uploads/userexpt/summary/fit_summary_modified.txt -o heatmap_plot -x #{heatmap_x} -y #{heatmap_y} -v '#{heatmap_value}' --title 'Heatmap: #{heatmap_value}' --keep-columns-missing-data --keep-rows-missing-data --kwargs 'cmap:Reds' --x-tick-labels-scale 1 --y-tick-labels-scale 1 --color-bar-labels-scale 0.6")
          else
            system("amiga fit -i private/uploads/userexpt -o fit")
            Python.exec("lib/scripts/otherscripts/simplifyfit.py private/uploads/userexpt/summary/fit_summary.txt")
            heatmap_fit_summary_path = Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt')
            raise "The heatmap plot failed" unless File.exist?(heatmap_fit_summary_path)
            system("amiga heatmap -i private/uploads/userexpt/summary/fit_summary_modified.txt -o heatmap_plot -x #{heatmap_x} -y #{heatmap_y} -v '#{heatmap_value}' --title 'Heatmap: #{heatmap_value}' --keep-columns-missing-data --keep-rows-missing-data --kwargs 'cmap:Reds' --x-tick-labels-scale 1 --y-tick-labels-scale 1 --color-bar-labels-scale 0.6")
          end
        else
          raise "Heatmap value, x-axis, or y-axis not selected"
        end
        heatmap_plot_path = Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'heatmap_plot.pdf')
        raise "The heatmap plot analysis failed" unless File.exist?(heatmap_plot_path)
        @heatmap_plot_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'heatmap_plot.pdf'))
        logger.debug("done with heatmap_plot ...")
      end

      if @selected_chart_types.include?('compare-parameters')
        system("amiga fit -i private/uploads/userexpt --sample-posterior --pool-by #{compare_parameters_pool} -o compare")
        system("amiga compare -i private/uploads/userexpt/summary/compare_summary.txt -o compare-parameters -s #{compare_finalsubset} --verbose")
        old_path = "compare-parameters.txt"
        new_path = "private/uploads/userexpt/models/compare-parameters.txt"
        File.rename(old_path, new_path) if File.exist?(old_path)
        fit_stats_sample_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'compare_summary.txt'))
        compare_params_txts = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'models', '*.txt'))
        logger.debug("compare_params_txts: #{compare_params_txts}")
        if compare_params_txts.empty? && fit_stats_sample_paths.empty?
          raise "The compare parameters analysis failed"
        end
        @compare_params_paths = compare_params_txts
        logger.debug("done with compare-parameters ...")
      end
      save # Save the instance of Job

      if @selected_chart_types.include?('test-hypothesis')
        system("amiga test -i private/uploads/userexpt -s #{test_finalsubset} -y #{hypothesis} -o 'test-hypothesis'")
        test_hypothesis_txts = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'models', 'test-hypothesis', '*report.txt'))
        test_hypothesis_pdfs = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'models', 'test-hypothesis', '*.pdf'))
        if test_hypothesis_txts.empty? && test_hypothesis_pdfs.empty?
          raise "The test hypothesis analysis failed"
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

      UserMailer.processedjob_email(file_names, self).deliver_now
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
      if self.status != "Failed"
        self.status = "Completed"
        self.end_time = DateTime.now
        save
      end
    end
  end

  def serve_image
    filename = params[:filename]
    file_path = Rails.root.join('private', 'uploads', 'userexpt', 'figures', filename)
    if File.exist?(file_path) && File.file?(file_path)
      send_file file_path, disposition: 'inline'
    else
      head :not_found
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

  def deleteoldfiles
    FileUtils.rm_rf(Rails.root.join('private', 'uploads', 'userexpt', 'figures'))
    FileUtils.rm_rf(Rails.root.join('private', 'uploads', 'userexpt', 'summary'))
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

