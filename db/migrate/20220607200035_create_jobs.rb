class CreateJobs < ActiveRecord::Migration[7.0]
  def change
    create_table :jobs do |t|
      t.integer :subsample
      t.string :factors, :array => true, :default => '{}'
      t.string :status
      t.string :metafile
      t.string :odfile
      t.string :pfile
      t.integer :user_id
      t.datetime :start_time
      t.datetime :end_time
      t.integer :rows
      t.integer :columns
      
      t.timestamps
    end
  end
end
