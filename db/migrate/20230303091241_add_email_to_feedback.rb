class AddEmailToFeedback < ActiveRecord::Migration[7.0]
  def change
    add_column :feedbacks, :email, :string
  end
end
