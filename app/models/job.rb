#!/usr/bin/env ruby
# require 'logger'
# LOGGER = Logger.new( 'log/log.txt', 'daily' )


class Job < ApplicationRecord
  belongs_to :user
  attr_accessor :title


  def analyze(chart_types, pool_replicates, pool_options_string, finalsubset, hypothesis, gp_pool_by_column, gp_subset_choice, gp_finalsubset)
    self.status = "Analyzing..."
    self.start_time = DateTime.now
    @selected_chart_types = chart_types || []
    @pool_replicates = pool_replicates
    @pool_options_string = pool_options_string || []
    @finalsubset = finalsubset
    @hypothesis = hypothesis
    @gp_pool_by_column = gp_pool_by_column
    @gp_subset_choice = gp_subset_choice
    @gp_finalsubset = gp_finalsubset
    raw_data_results = nil
    fit_summary_path = nil
    fit_stats_path = nil
    compare_params_paths = nil
    compare_params_pdf_paths = nil
    gp_plot_path = nil

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
        Python.exec("lib/scripts/otherscripts/gpplot.py private/uploads/userexpt/derived")
        gp_plot_path = Rails.root.join('private', 'uploads', 'userexpt', 'derived', 'gp_plot.pdf')
        raise "The GP plot analysis failed" unless File.exist?(gp_plot_path)
        @gp_plot_path = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'derived', 'gp_plot.pdf'))
        logger.debug("done with gp_plot ...")
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "no"
        system("amiga fit -i private/uploads/userexpt -o fit")

        # Check if fit_summary_modified.txt exists
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

      if @selected_chart_types.include?('compare-parameters')
        system("amiga test -i private/uploads/userexpt -s #{finalsubset} -y #{hypothesis} -o 'compare-parameters'")
        
        # Get matching files
        compare_params_txts = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'models', 'compare-parameters', '*report.txt'))
        compare_params_pdfs = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'models', 'compare-parameters', '*.pdf'))

        # Raise if no output files found
        if compare_params_txts.empty? && compare_params_pdfs.empty?
          raise "The compare parameters analysis failed"
        end

        # Set instance variables
        @compare_params_paths = compare_params_txts
        @compare_params_pdf_paths = compare_params_pdfs

        logger.debug("done with compare-parameters ...")
      end
      save # Save the instance of Job

      # Prepare the file names to be sent in the email
      file_names = []
      file_names += @raw_data_pdf_paths if @raw_data_pdf_paths.present?
      file_names += @fit_stats_paths if @fit_stats_paths.present?
      file_names += @compare_params_paths if @compare_params_paths.present?
      file_names += @compare_params_pdf_paths if @compare_params_pdf_paths.present?
      file_names += @gp_plot_path if @gp_plot_path.present?


      # Send email to the user with the file names and the job object and mark job as completed
      UserMailer.processedjob_email(file_names, self).deliver_now
    rescue => e
      logger.error("Error processing job: #{e.message}")
      # If an exception occurs, set the status to "Failed" and save the instance
      self.status = "Failed"
      save

      # Send a failed job notice email to the user
      UserMailer.failedjob_email(self, e.message).deliver_now
    ensure
      # Update the status to "Completed" only if there was no exception
      if self.status != "Failed"
        self.status = "Completed"
        save # Save the updated status
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
end
