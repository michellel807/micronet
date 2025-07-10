class HeatmapGenerator
  def self.generate_heatmap(input:, output_basename:, x:, y:, v:, title: 'Heatmap', format: 'png')
    # Ensure output directory exists
    output_dir = File.dirname(output_basename)
    FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)

    # Build the command
    cmd = "python lib/scripts/otherscripts/generate_heatmap.py" \
          " -i #{input}" \
          " -o #{output_basename}" \
          " -x #{x}" \
          " -y #{y}" \
          " -v \"#{v}\"" \
          " --title \"#{title}\"" \
          " --format #{format} 2>&1"

    Rails.logger.debug("Running heatmap command: #{cmd}")
    result = `#{cmd}`

    output_file = "#{output_basename}.#{format}"
    unless File.exist?(output_file)
      Rails.logger.error("Heatmap generation failed. Python output: #{result}")
      raise "The heatmap analysis failed. Python output: #{result}"
    end

    output_file
  end
end 