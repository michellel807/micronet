class AddSubmissionNumbersToJobs < ActiveRecord::Migration[7.0]
  def up
    add_column :jobs, :submission_number, :bigint
    add_index :jobs, :submission_number, unique: true

    # Preserve identifiers already used in emails for submitted jobs.
    execute <<~SQL
      UPDATE jobs SET submission_number = id
      WHERE status IN ('Job submitted', 'Analyzing...', 'Completed', 'Completed with warnings', 'Failed', 'Cancelled')
    SQL

    create_table :job_number_counters do |t|
      t.bigint :last_number, default: 0, null: false
    end
    execute <<~SQL
      INSERT INTO job_number_counters (id, last_number)
      SELECT 1, COALESCE(MAX(submission_number), 0) FROM jobs
    SQL
  end

  def down
    drop_table :job_number_counters
    remove_column :jobs, :submission_number
  end
end
