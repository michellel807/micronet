require "securerandom"

# Files for an unsubmitted analysis. This is deliberately not a database record.
class UploadWorkspace
  include UploadDirectories

  class Expired < StandardError; end
  TOKEN_FORMAT = /\A[0-9a-f]{32}\z/
  RETENTION = 24.hours
  attr_reader :token

  def self.root
    UploadDirectories.root.join("temporary")
  end

  def self.create!
    workspace = new(SecureRandom.hex(16))
    workspace.ensure_upload_directories!
    FileUtils.touch(workspace.upload_root.join(".lock"))
    workspace
  end

  def self.find(token)
    return unless token.is_a?(String) && TOKEN_FORMAT.match?(token)

    workspace = new(token)
    workspace if workspace.upload_root.directory? && !workspace.upload_root.symlink?
  end

  def initialize(token)
    raise ArgumentError, "Invalid upload token" unless TOKEN_FORMAT.match?(token.to_s)

    @token = token
  end

  def upload_root
    self.class.root.join(token)
  end

  def with_lock
    raise Expired unless upload_root.directory?

    File.open(upload_root.join(".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      raise Expired unless upload_root.directory? && File.mtime(upload_root) >= RETENTION.ago

      FileUtils.touch(upload_root)
      begin
        yield
      ensure
        FileUtils.touch(upload_root) if upload_root.directory?
      end
    end
  rescue Errno::ENOENT
    raise Expired
  end

  def discard!
    with_lock { clear_uploads! }
  rescue Expired
    nil
  end

  def self.cleanup_expired!
    return 0 unless root.directory?

    removed = 0
    root.children.each do |path|
      next unless TOKEN_FORMAT.match?(path.basename.to_s) && path.directory? && !path.symlink?

      begin
        last_activity = File.mtime(path)
        had_lock = path.join(".lock").exist?
        File.open(path.join(".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          next unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          next unless path.directory?
          next unless (had_lock ? File.mtime(path) : last_activity) < RETENTION.ago

          FileUtils.rm_rf(path)
          removed += 1
        end
      rescue Errno::ENOENT
        next
      end
    end
    removed
  end
end
