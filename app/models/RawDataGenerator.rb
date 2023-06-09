class RawDataGenerator
  def self.generate_raw_data()
    system("source activate lib/envs/amigacondaenv/ && lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py summarize -i public/uploads/userexpt")
    
    raw_data_pdf_paths = Dir.glob(Rails.root.join('public', 'uploads', 'userexpt', 'figures', '*.pdf'))
    
    raw_data_png_paths = []
    raw_data_pdf_paths.each do |pdf_path|
      png_path = pdf_path.sub('.pdf', '.png')
      require "mini_magick"
      MiniMagick::Tool::Convert.new do |convert|
        convert << pdf_path
        convert << png_path
      end
      raw_data_png_paths << png_path
    end
    
    { raw_data_pdf_paths: raw_data_pdf_paths, raw_data_png_paths: raw_data_png_paths }
  end
end

