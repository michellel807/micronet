class Job < ApplicationRecord
  belongs_to :user
  attr_accessor :title

  def analyze(chart_types, pool_replicates, pool_options_string)
    self.status = "Analyzing..."
    @selected_chart_types = chart_types || []
    @pool_replicates = pool_replicates
    @pool_options_string = pool_options_string || []

    if @selected_chart_types.include?('raw_data')
      raw_data_results = RawDataGenerator.generate_raw_data()
      @raw_data_pdf_paths = raw_data_results[:raw_data_pdf_paths]
    end

    if @selected_chart_types.include?('fit_stats') && @pool_replicates == "no"
      system("source activate lib/envs/amigacondaenv/ && lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt -o fit")
      @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary.txt'))
    end

    if @selected_chart_types.include?('fit_stats') && @pool_replicates == "yes"
      system("source activate lib/envs/amigacondaenv/ && lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt --pool-by '#{pool_options_string}' -o fit")
      @fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', 'fit_summary.txt'))  
    end

    save # Save the instance of Job

    # Prepare the file names to be sent in the email
    file_names = []
    file_names += @raw_data_pdf_paths if @raw_data_pdf_paths.present?
    file_names += @fit_stats_paths if @fit_stats_paths.present?

    # Send email to the user with the file names and the job object and mark job as completed
    UserMailer.processedjob_email(file_names, self).deliver_now
    self.completed = true
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
