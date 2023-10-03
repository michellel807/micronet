class Python

  def self.exec(python_script)
    args = ["bash", "-c", "source activate #{Rails.configuration.python_conda_location} && python #{python_script}"]
    Rails.logger.debug("Command: |#{args.join(' ')}|")
    system(*args)
  end

end

