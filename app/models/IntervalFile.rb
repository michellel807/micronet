require 'csv'

class IntervalFile
  attr_reader :file_path, :error_message, :plate_id_values

  def initialize(file)
    @file = file
    @plate_id_values = []
    valid_extensions = ['.txt', '.asc', '.tsv', '.csv']
    
    if valid_extensions.include?(File.extname(file.original_filename).downcase)
        @file_path = save_file(file)
    else
        @error_message = 'Invalid interval file format. Please ensure that your meta file is a .asc, .txt, .tsv, or .csv file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path)
  end

  private

  def save_file(file)
    directory_path = Rails.root.join('private', 'uploads', 'userexpt', 'parameters')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)

    original_filename = file.original_filename
    new_filename = "interval.txt"
    txt_file = directory_path.join(new_filename)
    file_extension = File.extname(file.original_filename).downcase

    File.open(txt_file, 'w') do |out|
      if file_extension == '.csv'
        # Parse CSV file
        CSV.foreach(file.path, encoding: 'UTF-8') do |row|
          out.puts row.join("\t")
          first_cell = row[0]&.strip
          next if first_cell && first_cell.match?(/plate[_ ]?id/i)  # skip header (case-insensitive)
          @plate_id_values << first_cell if first_cell && !first_cell.empty?
        end
      else
        # Parse tab-separated file (.txt, .tsv, .asc)
        File.open(file.path, 'r:ISO-8859-1') do |f|
          f.each_line.with_index do |line, index|
            utf8_line = line.encode('UTF-8', 'ISO-8859-1', invalid: :replace, replace: '')
            cleaned = utf8_line.gsub(/\x00/, '')
            out.puts cleaned
            first_cell = cleaned.strip.split("\t")[0]&.strip
            next if first_cell && first_cell.match?(/plate[_ ]?id/i)  # skip header (case-insensitive)
            @plate_id_values << first_cell if first_cell && !first_cell.empty?
          end
        end
      end
    end

    @plate_id_values.uniq! # optional: remove duplicates
    txt_file.to_s
  end
end
