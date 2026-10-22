class AddSubmissionOptionsToJobs < ActiveRecord::Migration[7.0]
  def change
    add_column :jobs, :submission_options, :jsonb, default: {}, null: false
  end
end
