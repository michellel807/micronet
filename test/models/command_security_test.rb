require "test_helper"
require "minitest/mock"
require "rbconfig"

class CommandSecurityTest < ActiveSupport::TestCase
  test "Python passes shell syntax as literal arguments" do
    payload = "a'; $(touch /tmp/micronet-injection); echo 'b"
    Python.exec("script.py", payload) do |*command|
      assert_equal ["/opt/uvenv/bin/python", "script.py", payload], command
    end
  end

  test "analysis runner never invokes shell syntax in an argument" do
    marker = Rails.root.join("tmp", "command-injection-#{SecureRandom.hex(6)}")
    job = Job.new
    job.stub(:cancelled?, false) do
      assert job.run_cancellable_command(RbConfig.ruby, "-e", "exit(ARGV.length == 1 ? 0 : 1)", "$(touch #{marker}); echo injected")
    end
    assert_not marker.exist?
  ensure
    marker&.delete if marker&.exist?
  end
end
