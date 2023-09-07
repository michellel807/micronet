class Job < ApplicationRecord
  belongs_to :user
  attr_accessor :title


  def analyze(chart_types, pool_replicates, pool_options_string, finalsubset, hypothesis)
    self.status = "Analyzing..."
    self.start_time = DateTime.now
    @selected_chart_types = chart_types || []
    @pool_replicates = pool_replicates
    @pool_options_string = pool_options_string || []
    @finalsubset = finalsubset
    @hypothesis = hypothesis

    begin

      if @selected_chart_types.include?('raw_data')
        raw_data_results = RawDataGenerator.generate_raw_data()
        @raw_data_pdf_paths = raw_data_results[:raw_data_pdf_paths]
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "no"
        system("bash", "-c", "source activate #{Rails.configuration.python_conda_location} && python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt -o fit")

        # Check if fit_summary_modified.txt exists
        fit_summary_path = Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt')
        if File.exist?(fit_summary_path)
          system("bash", "-c", "source activate #{Rails.configuration.python_conda_location} && python lib/scripts/otherscripts/simplifyfit.py private/uploads/userexpt/summary/fit_summary.txt")
          @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt'))
        else
          raise "fit_summary_modified.txt not found"
        end
      end

      if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes"
        system("bash", "-c", "source activate #{Rails.configuration.python_conda_location} && python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt --pool-by '#{pool_options_string}' -o fit")
        system("bash", "-c", "source activate #{Rails.configuration.python_conda_location} && python lib/scripts/otherscripts/simplifyfit.py private/uploads/userexpt/summary/fit_summary.txt")
        @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary_modified.txt'))
      end

      if @selected_chart_types.include?('compare-parameters')
        system("bash", "-c", "source activate #{Rails.configuration.python_conda_location} && python lib/scripts/amigagitsimplified/amiga.py test -i private/uploads/userexpt -s #{finalsubset} -y #{hypothesis} -o 'compare-parameters'")
        @compare_params_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'models','compare-parameters', '*report.txt'))
        @compare_params_pdf_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'models','compare-parameters','*pdf'))

      end
      save # Save the instance of Job

      # Prepare the file names to be sent in the email
      file_names = []
      file_names += @raw_data_pdf_paths if @raw_data_pdf_paths.present?
      file_names += @fit_stats_paths if @fit_stats_paths.present?
      file_names += @compare_params_paths if @compare_params_paths.present?
      file_names += @compare_params_pdf_paths if @compare_params_pdf_paths.present?


      # Send email to the user with the file names and the job object and mark job as completed
      UserMailer.processedjob_email(file_names, self).deliver_now
    rescue => e
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