class CreateFeedbacks < ActiveRecord::Migration[7.0]
  def change
    create_table :feedbacks do |t|
      t.string :like
      t.string :issue
      t.string :recommend
      t.string :suggestions
      t.integer :job_id

      t.timestamps
    end
  end
end
