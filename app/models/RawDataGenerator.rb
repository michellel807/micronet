class RawDataGenerator
  def self.generate_raw_data(upload_root)
    system("amiga", "summarize", "-i", upload_root.to_s)

    figures_dir = upload_root.join("figures")
    raw_data_pdf_paths = Dir.glob(figures_dir.join("*.pdf"))

    raw_data_png_paths = []

    raw_data_pdf_paths.each do |pdf_path|
      png_path = pdf_path.sub(".pdf", ".png")

      require "open3"
      stdout, stderr, status = Python.exec(Rails.root.join("lib/scripts/otherscripts/renderpdf.py").to_s, pdf_path, png_path) do |*arguments|
        Open3.capture3(*arguments)
      end
      raise "PDF preview rendering failed: #{stderr}" unless status.success?

      raw_data_png_paths.concat(JSON.parse(stdout))
    end

    {
      raw_data_pdf_paths: raw_data_pdf_paths,
      raw_data_png_paths: raw_data_png_paths
    }
  end
end
