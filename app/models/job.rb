#!/usr/bin/env ruby
# require 'logger'
# LOGGER = Logger.new( 'log/log.txt', 'daily' )


class Job < ApplicationRecord
  belongs_to :user
  attr_accessor :title



  def analyze(chart_types, pool_replicates, pool_options_string, finalsubset, hypothesis, compare_parameters_pool, finalsubset_pooled, heatmap_params = {})

    self.status = "Analyzing..."
    self.start_time = DateTime.now
    @selected_chart_types = chart_types || []
    @pool_replicates = pool_replicates
    @pool_options_string = pool_options_string || []
    @finalsubset = finalsubset
    @hypothesis = hypothesis
    @compare_parameters_pool = compare_parameters_pool
    @finalsubset_pooled = finalsubset_pooled
    raw_data_results = nil
    fit_summary_path = nil
    fit_stats_path = nil
    compare_params_paths = nil
    test_hypothesis_paths = nil
    test_hypothesis_pdf_paths = nil
    compare_params_pdf_paths = nil
    file_names = []


    begin

      logger.debug("Starting analysis...")
      logger.debug("Heatmap params: #{heatmap_params.inspect}")
      raw_data_results = RawDataGenerator.generate_raw_data()
      if @selected_chart_types.include?('raw_data')
        raise "The plotting analysis failed" unless raw_data_results[:raw_data_pdf_paths].present?
        @raw_data_pdf_paths = raw_data_results[:raw_data_pdf_paths].select { |path| File.exist?(path) }
      end
      logger.debug("done with raw_data ...")

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "no"
        system("amiga fit -i private/uploads/userexpt -o fit")
        fit_summary_path = Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt')
        Python.exec("lib/scripts/otherscripts/simplifyfit.py private/uploads/userexpt/summary/fit_summary.txt")
        raise "The fit statistics analysis failed" unless File.exist?(fit_summary_path)
        @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt'))
        logger.debug("done with fit_stats yes ...")
        if File.exist?(fit_summary_path) && heatmap_params[:generate_heatmap] == 'yes'
          heatmap_x = heatmap_params[:heatmap_x]
          heatmap_y = heatmap_params[:heatmap_y]
          heatmap_v = heatmap_params[:heatmap_v]
          heatmap_format = heatmap_params[:heatmap_format] || 'png'
          heatmap_title = heatmap_params[:heatmap_title].presence || 'AMiGA Heatmap'
          safe_title = heatmap_title.gsub(/[^0-9A-Za-z\-]/, '_')
          figures_dir = Rails.root.join('private', 'uploads', 'userexpt', 'figures')
          FileUtils.mkdir_p(figures_dir) unless Dir.exist?(figures_dir)
          heatmap_basename = figures_dir.join(safe_title)
          begin
            heatmap_path = HeatmapGenerator.generate_heatmap(
              input: fit_summary_path,
              output_basename: heatmap_basename,
              x: heatmap_x,
              y: heatmap_y,
              v: heatmap_v,
              title: heatmap_title,
              format: heatmap_format
            )
            @heatmap_path = heatmap_path
            file_names << @heatmap_path unless file_names.include?(@heatmap_path)
            @heatmap_relative_path = "uploads/userexpt/figures/#{safe_title}.#{heatmap_format}"
          rescue => e
            logger.error("Heatmap generation failed: #{e.message}")
            raise "The heatmap analysis failed. #{e.message}"
          end
        end
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes"
        system("amiga fit -i private/uploads/userexpt --pool-by #{pool_options_string} -o fit")
        Python.exec("lib/scripts/otherscripts/simplifyfit.py private/uploads/userexpt/summary/fit_summary.txt")
        fit_stats_path = Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt')
        raise "The fit statistics (pooling requested) analysis failed" if not File.exist?(fit_stats_path)
        @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt'))
        logger.debug("done with fit_stats no ...")
        if File.exist?(fit_stats_path) && heatmap_params[:generate_heatmap] == 'yes'
          heatmap_x = heatmap_params[:heatmap_x]
          heatmap_y = heatmap_params[:heatmap_y]
          heatmap_v = heatmap_params[:heatmap_v]
          heatmap_format = heatmap_params[:heatmap_format] || 'png'
          heatmap_title = heatmap_params[:heatmap_title].presence || 'AMiGA Heatmap'
          safe_title = heatmap_title.gsub(/[^0-9A-Za-z\-]/, '_')
          figures_dir = Rails.root.join('private', 'uploads', 'userexpt', 'figures')
          FileUtils.mkdir_p(figures_dir) unless Dir.exist?(figures_dir)
          heatmap_basename = figures_dir.join(safe_title)
          begin
            heatmap_path = HeatmapGenerator.generate_heatmap(
              input: fit_stats_path,
              output_basename: heatmap_basename,
              x: heatmap_x,
              y: heatmap_y,
              v: heatmap_v,
              title: heatmap_title,
              format: heatmap_format
            )
            @heatmap_path = heatmap_path
            file_names << @heatmap_path unless file_names.include?(@heatmap_path)
            @heatmap_relative_path = "uploads/userexpt/figures/#{safe_title}.#{heatmap_format}"
          rescue => e
            logger.error("Heatmap generation failed: #{e.message}")
            raise "The heatmap analysis failed. #{e.message}"
          end
        end
      end

      if @selected_chart_types.include?('compare-parameters')
        system("amiga fit -i private/uploads/userexpt --sample-posterior --pool-by #{compare_parameters_pool} -o fit")
        system("amiga compare -i private/uploads/userexpt/summary/fit_summary.txt -o compare-parameters -s #{finalsubset_pooled} --verbose")
        old_path = "compare-parameters.txt"
        new_path = "private/uploads/userexpt/models/compare-parameters.txt"
        File.rename(old_path, new_path) if File.exist?(old_path)
        fit_stats_sample_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary.txt'))
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
        system("amiga test -i private/uploads/userexpt -s #{finalsubset} -y #{hypothesis} -o 'test-hypothesis'")
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
      if defined?(@heatmap_path) && @heatmap_path.present? && !file_names.include?(@heatmap_path)
        file_names << @heatmap_path
      end
      file_links = []
      (file_names || []).each do |f|
        if f.start_with?(Rails.root.to_s)
          rel = File.basename(f)
          file_links << Rails.application.routes.url_helpers.download_file_url(rel, host: 'localhost:3000')
        end
      end
      if defined?(@heatmap_relative_path) && @heatmap_relative_path.present?
        rel = File.basename(@heatmap_relative_path)
        url = Rails.application.routes.url_helpers.download_file_url(rel, host: 'localhost:3000')
        file_links << url unless file_links.include?(url)
      end
      file_links.uniq!

      UserMailer.processedjob_email(file_names, self, file_links).deliver_now
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
    file_names = []
    file_names += @raw_data_pdf_paths if defined?(@raw_data_pdf_paths) && @raw_data_pdf_paths.present?
    file_names += @fit_stats_paths if defined?(@fit_stats_paths) && @fit_stats_paths.present?
    file_names += @compare_params_paths if defined?(@compare_params_paths) && @compare_params_paths.present?
    file_names += @compare_params_pdf_paths if defined?(@compare_params_pdf_paths) && @compare_params_pdf_paths.present?
    file_names << @heatmap_path if defined?(@heatmap_path) && @heatmap_path.present? && !file_names.include?(@heatmap_path)
    file_links = []
    (file_names || []).each do |f|
      if f.start_with?(Rails.root.to_s)
        rel = File.basename(f)
        file_links << Rails.application.routes.url_helpers.download_file_url(rel, host: 'localhost:3000')
      end
    end
    if defined?(@heatmap_relative_path) && @heatmap_relative_path.present?
      rel = File.basename(@heatmap_relative_path)
      url = Rails.application.routes.url_helpers.download_file_url(rel, host: 'localhost:3000')
      file_links << url unless file_links.include?(url)
    end
    file_links.uniq!
    user = User.find(self.user_id)
    UserMailer.confirm_email(self, user, file_names, file_links).deliver_now
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
end

