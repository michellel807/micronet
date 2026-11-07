class RScript
  # Like Python.exec: an argument vector for Rscript, never a shell command.
  def self.exec(script, *arguments)
    args = [ENV.fetch("RSCRIPT_EXECUTABLE", "Rscript"), script.to_s, *arguments.map(&:to_s)]
    block_given? ? yield(*args) : system(*args)
  end
end
