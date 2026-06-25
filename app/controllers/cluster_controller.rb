  class ClusterController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :verify_cluster_token!

    def callback
      job = Job.find_by(id: params[:job_id])
      return render json: { error: "job not found" }, status: :not_found unless job

      payload = callback_params
      state = payload[:state].to_s.upcase
      slurm_job_id = payload[:slurm_job_id].to_s
      exit_code = payload[:exit_code].to_s
      message = payload[:message].to_s

      job.slurm_job_id = slurm_job_id if slurm_job_id.present?

      case state
      when "COMPLETED"
        job.cluster_status = "completed"
        job.status = "Completed"
        job.completed = true if job.respond_to?(:completed)
        job.end_time = Time.current if job.respond_to?(:end_time)
      when "FAILED", "CANCELLED", "TIMEOUT", "OUT_OF_MEMORY", "OOM"
        job.cluster_status = state.downcase
        job.status = "Failed: #{state}"
        job.completed = false if job.respond_to?(:completed)
        job.end_time = Time.current if job.respond_to?(:end_time)
      else
        job.cluster_status = state.downcase.presence || "unknown"
        job.status = "Cluster status: #{state.presence || 'UNKNOWN'}"
      end

      job.save!

      render json: {
        ok: true,
        job_id: job.id,
        slurm_job_id: job.slurm_job_id,
        cluster_status: job.cluster_status,
        status: job.status,
        exit_code: exit_code,
        message: message
      }, status: :ok
    rescue ActionController::ParameterMissing => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def verify_cluster_token!
      expected = ENV["DCC_CALLBACK_TOKEN"].to_s
      provided = request.headers["X-Cluster-Token"].to_s

      if expected.blank? || provided.blank? || !ActiveSupport::SecurityUtils.secure_compare(provided, expected)
        render json: { error: "unauthorized" }, status: :unauthorized
      end
    end

    def callback_params
      params.permit(:slurm_job_id, :state, :exit_code, :message)
    end
  end
