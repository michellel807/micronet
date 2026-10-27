require "shellwords"

class Python
  def self.exec(script, *arguments)
    # Support older callers while never invoking a shell.
    script_arguments = arguments.empty? && script.is_a?(String) ? Shellwords.split(script) : [script, *arguments]
    args = [ENV.fetch("PYTHON_EXECUTABLE", "/opt/uvenv/bin/python"), *script_arguments.map(&:to_s)]
    block_given? ? yield(*args) : system(*args)
  end
end
