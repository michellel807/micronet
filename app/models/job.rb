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
          system("amiga fit -i #{upload_root} --pool-by '#{gp_pool_by_column}' --save-gp-data -o plot")
        elsif @gp_subset_choice == "yes"
          system("amiga fit -i #{upload_root} -s #{gp_finalsubset} --pool-by '#{gp_pool_by_column}' --save-gp-data -o plot")
        else
          raise "Invalid GP subset choice"
        end
        Python.exec("lib/scripts/otherscripts/gpplot.py #{derived_dir} #{gp_finalsubset}")
        gp_plot_path = derived_dir.join('gp_plot.pdf')
        gp_plot_data = derived_dir.join('plot_gp_data.txt')
        raise "The GP plot analysis failed" unless File.exist?(gp_plot_path) && File.exist?(gp_plot_data)
        @gp_plot_path = Dir.glob(derived_dir.join('gp_plot.pdf'))
        @gp_plot_data = Dir.glob(derived_dir.join('plot_gp_data.txt'))
        logger.debug("done with gp_plot ...")
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "no"
        system("amiga fit -i #{upload_root} -o fit")
        fit_summary_path = summary_dir.join('fit_summary_modified.txt')
        Python.exec("lib/scripts/otherscripts/simplifyfit.py #{summary_dir.join('fit_summary.txt')}")
        raise "The fit statistics analysis failed" unless File.exist?(fit_summary_path)
        @fit_stats_paths = Dir.glob(summary_dir.join('fit_summary_modified.txt'))
        logger.debug("done with fit_stats yes ...")
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes"
        system("amiga fit -i #{upload_root} --pool-by '#{pool_options_string}' -o fit")
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
            system("amiga heatmap -i #{summary_dir.join('fit_summary_modified.txt')} -o heatmap_plot -x \"#{heatmap_x}\" -y \"#{heatmap_y}\" -v \"#{heatmap_value}\" --title 'Heatmap: #{heatmap_value}' --keep-columns-missing-data --keep-rows-missing-data --kwargs 'cmap:Reds' --x-tick-labels-scale 1 --y-tick-labels-scale 1 --color-bar-labels-scale 0.6")
          else
            heatmap_x = @heatmap_x == "Well positions" ? "Well" : @heatmap_x
            heatmap_y = @heatmap_y == "Well positions" ? "Well" : @heatmap_y
            puts "HEATMAP VALUE = #{@heatmap_value.inspect}"
            puts "HEATMAP X = #{@heatmap_x.inspect}"
            puts "HEATMAP Y = #{@heatmap_y.inspect}"
            system("amiga fit -i #{upload_root} -o fit")
            Python.exec("lib/scripts/otherscripts/simplifyfit.py #{summary_dir.join('fit_summary.txt')}")
            heatmap_fit_summary_path = summary_dir.join('fit_summary_modified.txt')
            raise "The heatmap plot failed" unless File.exist?(heatmap_fit_summary_path)
            system("amiga heatmap -i #{summary_dir.join('fit_summary_modified.txt')} -o heatmap_plot -x \"#{heatmap_x}\" -y \"#{heatmap_y}\" -v \"#{heatmap_value}\" --title 'Heatmap: #{heatmap_value}' --keep-columns-missing-data --keep-rows-missing-data --kwargs 'cmap:Reds' --x-tick-labels-scale 1 --y-tick-labels-scale 1 --color-bar-labels-scale 0.6")
          end
        else
          raise "Heatmap value, x-axis, or y-axis not selected"
        end
        heatmap_plot_path = summary_dir.join('heatmap_plot.pdf')
        raise "The heatmap plot analysis failed" unless File.exist?(heatmap_plot_path)
        @heatmap_plot_paths = Dir.glob(summary_dir.join('heatmap_plot.pdf'))
        logger.debug("done with heatmap_plot ...")
      end

      if @selected_chart_types.include?('compare-parameters')
        system("amiga fit -i #{upload_root} --sample-posterior --pool-by #{compare_parameters_pool} -o compare")
        system("amiga compare -i #{summary_dir.join('compare_summary.txt')} -o compare-parameters -s #{compare_finalsubset} --verbose")
        old_path = "compare-parameters.txt"
        new_path = models_dir.join("compare-parameters.txt")
        File.rename(old_path, new_path) if File.exist?(old_path)
        fit_stats_sample_paths = Dir.glob(summary_dir.join('compare_summary.txt'))
        compare_params_txts = Dir.glob(models_dir.join('*.txt'))
        logger.debug("compare_params_txts: #{compare_params_txts}")
        if compare_params_txts.empty? && fit_stats_sample_paths.empty?
          raise "The compare parameters analysis failed"
        end
        @compare_params_paths = compare_params_txts
        logger.debug("done with compare-parameters ...")
      end
      save # Save the instance of Job

      if @selected_chart_types.include?('test-hypothesis')
        system("amiga test -i #{upload_root} -s #{test_finalsubset} -y #{hypothesis} -o 'test-hypothesis'")
        test_hypothesis_txts = Dir.glob(models_dir.join('test-hypothesis', '*report.txt'))
        test_hypothesis_pdfs = Dir.glob(models_dir.join('test-hypothesis', '*.pdf'))
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
      self.status = "Failed"
      save
      UserMailer.failedjob_email(self, e.message).deliver_now
    ensure
      if self.status != "Failed"
        self.status = "Completed"
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
    FileUtils.rm_rf(figures_dir)
    FileUtils.rm_rf(summary_dir)
  end

  def self.admin_can_manage_jobs?(admin)
    admin&.is_admin?
  end

  def admin_can_manage_jobs?(admin)
    admin&.is_admin?
  end
end

