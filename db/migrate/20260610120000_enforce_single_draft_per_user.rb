class EnforceSingleDraftPerUser < ActiveRecord::Migration[7.0]
  DRAFT = "In Progress".freeze

  def up
    # Collapse any pre-existing duplicate drafts: keep the most recent
    # "In Progress" job per user, destroy the older ones.
    grouped = Job.where(status: DRAFT).order(created_at: :desc).group_by(&:user_id)
    grouped.each_value do |drafts|
      drafts.drop(1).each(&:destroy)
    end

    # Hard guarantee at the DB level: a user may have at most one draft.
    add_index :jobs, :user_id,
              unique: true,
              where: "status = '#{DRAFT}'",
              name: "index_jobs_on_single_active_draft"
  end

  def down
    remove_index :jobs, name: "index_jobs_on_single_active_draft"
  end
end
