class RemoveMetafileFromJobs < ActiveRecord::Migration[7.0]
  def change
    remove_column :jobs, :metafile, :string
    remove_column :jobs, :odfile, :string
    remove_column :jobs, :pfile, :string
  end
end
