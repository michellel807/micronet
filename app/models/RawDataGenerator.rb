class RawDataGenerator
  def self.generate_raw_data(upload_root)
<<<<<<< HEAD
    system("amiga summarize -i #{upload_root}")

    raw_data_pdf_paths = Dir.glob(upload_root.join('figures', '*.pdf'))
=======
    # FileUtils.rm_rf(upload_root.join("figures")) # clear out figures first

    system("amiga summarize -i #{upload_root}")

    figures_dir = upload_root.join("figures")
    raw_data_pdf_paths = Dir.glob(figures_dir.join("*.pdf"))
>>>>>>> 9c63dc349 (removed all userexpt commands)

    raw_data_png_paths = []

    raw_data_pdf_paths.each do |pdf_path|
      png_path = pdf_path.sub(".pdf", ".png")

      require "mini_magick"

      MiniMagick::Tool::Convert.new do |convert|
        convert << pdf_path
        convert << png_path
      end

      raw_data_png_paths << png_path
    end

    {
      raw_data_pdf_paths: raw_data_pdf_paths,
      raw_data_png_paths: raw_data_png_paths
    }
  end
<<<<<<< HEAD
end
=======
end
>>>>>>> 9c63dc349 (removed all userexpt commands)
