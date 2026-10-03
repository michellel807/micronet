require "set"

# Deletes leftover upload folders from jobs that have already been deleted.
# Each job's files live in private/uploads/jobs/<id>/. When a job is deleted,
# its folder should go too. This cleans up any folders left behind from before.
namespace :uploads do
  desc "Delete upload folders for jobs that no longer exist"
  task sweep_orphans: :environment do
    puts "Starting orphan sweep..."
    jobs_root = Rails.root.join("private", "uploads", "jobs")

    unless Dir.exist?(jobs_root)
      puts "No uploads folder yet — nothing to clean up."
      next
    end

    live_ids = Job.pluck(:id).map(&:to_s).to_set
    puts "#{live_ids.size} jobs still alive in the database."
    removed  = 0

    Dir.children(jobs_root).each do |dir_name|
      next if live_ids.include?(dir_name)

      puts "Orphan found — deleting folder for job #{dir_name}."
      FileUtils.rm_rf(jobs_root.join(dir_name))
      removed += 1
      Rails.logger.info("[uploads:sweep_orphans] removed orphan #{dir_name}")
    end

    puts "All done — cleaned up #{removed} orphaned folder#{removed == 1 ? '' : 's'}."
  end
end
