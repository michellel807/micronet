# Jobs are growth (AMiGA) analyses unless marked otherwise. RNA-seq jobs keep
# their validated settings in analysis_config rather than in queue arguments.
class AddAnalysisTypeToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :analysis_type, :string, default: "growth", null: false
    add_column :jobs, :analysis_config, :jsonb, default: {}, null: false
  end
end
