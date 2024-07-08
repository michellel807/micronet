class AddConfirmTimeToJobs < ActiveRecord::Migration[7.0]
  def change
    add_column :jobs, :confirm_time, :datetime
  end
end
