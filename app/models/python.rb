class Python

  def self.exec(python_script)
    args = ["bash", "-c", "/opt/uvenv/bin/python #{python_script}"]
    Rails.logger.debug("Command: |#{args.join(' ')}|")
    system(*args)
  end

end

