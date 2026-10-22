class UseTemporaryUploadWorkspaces < ActiveRecord::Migration[7.0]
  def change
    add_column :jobs, :upload_token, :string
    add_index :jobs, :upload_token, unique: true
    # submission_number remains solely to preserve historical emailed numbers.
    drop_table :job_number_counters do |t|
      t.bigint :last_number, default: 0, null: false
    end
  end
end
