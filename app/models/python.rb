class Python

  def self.exec(python_script)
    args = ["bash", "-c", "/opt/uvenv/bin/python #{python_script}"]
    Rails.logger.debug("Command: |#{args.join(' ')}|")
    block_given? ? yield(*args) : system(*args)
  end

end
