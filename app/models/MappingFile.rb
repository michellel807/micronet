require 'csv'

class MappingFile
  attr_reader :file_path, :plate_id, :error_message

  def initialize(file, upload_root:)
    @file = file
    @upload_root = upload_root
    valid_extensions = ['.txt', '.asc', '.tsv', '.csv']
    if valid_extensions.include?(File.extname(file.original_filename).downcase)
      print("Valid mapping file detected: #{file.original_filename}\n")
      @file_path = save_file(file)
    else
      @error_message = 'Invalid mapping file format. Please ensure that your mapping file is a .asc, .txt, .tsv, or .csv file and try again.'
    end
  end

  def valid?
    @file_path && File.exist?(@file_path) && File.file?(@file_path) 
  end
  
  private

  def save_file(file)
    directory_path = @upload_root.join('mapping')
    FileUtils.mkdir_p(directory_path) unless Dir.exist?(directory_path)
  
    original_filename = file.original_filename
    file_extension = File.extname(original_filename).downcase
    plate_id = ""
  
    if file_extension == '.csv'
      CSV.foreach(file.path, encoding: 'UTF-8') do |row|
        candidate = row[1]&.to_s&.strip
        next if candidate.nil? || candidate.empty? || candidate.casecmp('Plate_ID').zero?

        plate_id = candidate
        break
      end
    else
      File.open(file.path, 'r:ISO-8859-1') do |f|
        f.each_line do |line|
          line_utf8 = line.encode('UTF-8', 'ISO-8859-1', invalid: :replace, replace: '')
          values = line_utf8.chomp.gsub(/\x00/, '').split("\t")
          candidate = values[1]&.strip
          next if candidate.nil? || candidate.empty? || candidate.casecmp('Plate_ID').zero?

          plate_id = candidate
          break
        end
      end
    end

    new_filename = "#{File.basename(plate_id, '.*')}.txt"
    txt_file = directory_path.join(new_filename)

    if file_extension == '.csv'
      File.open(txt_file, 'w') do |f|
        CSV.foreach(file.path, encoding: 'UTF-8') do |row|
          f.puts row.join("\t")
        end
      end
    else
      # Keep non-CSV inputs unchanged; AMiGA handles content validation/parsing.
      FileUtils.cp(file.path, txt_file)
    end

    @plate_id = plate_id
    txt_file.to_s
  end
end
