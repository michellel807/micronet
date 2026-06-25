class AddSlurmFieldsToJobs < ActiveRecord::Migration[7.0]
  def change
    add_column :jobs, :slurm_job_id, :string
    add_column :jobs, :cluster_status, :string
  end
end
