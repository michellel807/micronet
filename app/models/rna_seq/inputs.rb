require "csv"

module RnaSeq
  # Quick checks on an uploaded count matrix and sample sheet, so the web pages
  # can offer the right choices and reject obvious mistakes. The R script still
  # validates everything in full when the job runs.
  class Inputs
    class Invalid < StandardError; end

    MAX_FILE_BYTES = 200.megabytes
    MIN_SAMPLES = 4
    MIN_REPLICATES = 2
    # Matches DEFAULT_CONFIG$sample_column in lib/scripts/rnaseq/R/validate.R.
    SAMPLE_COLUMN = "sample".freeze
    COUNT_ROWS_CHECKED = 1000
    LIST_LIMIT = 5

    # Matches lib/scripts/rnaseq/enrichment.py: required and optional columns.
    ANNOTATION_COLUMNS = %w[gene_id term].freeze
    ANNOTATION_DEFAULT_SOURCE = "annotation".freeze

    attr_reader :sample_ids, :metadata_columns, :metadata_rows, :annotation_summary

    # annotations_path is optional: a gene annotation table for functional enrichment.
    def initialize(counts_path, metadata_path, annotations_path = nil)
      @counts_path = Pathname.new(counts_path)
      @metadata_path = Pathname.new(metadata_path)
      inspect_counts
      inspect_metadata
      check_samples_match
      inspect_annotations(Pathname.new(annotations_path)) if annotations_path
    end

    # Columns a user can compare on or use as covariates.
    def condition_columns
      metadata_columns - [SAMPLE_COLUMN]
    end

    # { level => number of samples }, in first-seen order.
    def levels(column)
      return {} unless condition_columns.include?(column)

      metadata_rows.each_with_object(Hash.new(0)) { |row, counts| counts[row[column]] += 1 }
    end

    # { [value of each column] => number of samples } for the samples whose
    # values are among filter's ({ column => allowed values }).
    def group_counts(columns, filter = {})
      metadata_rows
        .select { |row| filter.all? { |column, allowed| allowed.include?(row[column]) } }
        .map { |row| row.values_at(*columns) }
        .tally
    end

    def levels_by_column
      condition_columns.index_with { |column| levels(column) }
    end

    def self.delimiter_for(path)
      File.extname(path.to_s).downcase == ".csv" ? "," : "\t"
    end

    private

    def inspect_counts
      check_size(@counts_path, "count matrix")
      delimiter = self.class.delimiter_for(@counts_path)
      header = nil
      row_number = 0
      File.foreach(@counts_path, encoding: "bom|utf-8") do |line|
        line = line.chomp.delete_suffix("\r")
        next if line.strip.empty?

        fields = line.split(delimiter, -1).map { |field| unquote(field) }
        if header.nil?
          header = fields
          next
        end
        row_number += 1
        # Matrices written by R's write.csv omit the gene ID header; the R
        # script accepts them too (read_delimited in lib/scripts/rnaseq/R/io.R).
        header = [""] + header if row_number == 1 && fields.length == header.length + 1
        check_count_row(fields, header.length, row_number)
        break if row_number >= COUNT_ROWS_CHECKED
      end

      raise Invalid, "The count matrix is empty." if header.nil?
      raise Invalid, "The count matrix has a header row but no genes." if row_number.zero?

      @sample_ids = header.drop(1)
      raise Invalid, "The count matrix needs at least #{MIN_SAMPLES} sample columns after the gene ID column; it has #{@sample_ids.length}." if @sample_ids.length < MIN_SAMPLES
      raise Invalid, "The count matrix header has a blank sample name." if @sample_ids.any?(&:blank?)

      duplicates = duplicates_in(@sample_ids)
      raise Invalid, "The count matrix has duplicate sample columns: #{preview(duplicates)}." if duplicates.any?
    rescue ArgumentError, Encoding::InvalidByteSequenceError
      raise Invalid, "The count matrix is not a readable text file. Please upload a tab-separated (.tsv/.txt) or comma-separated (.csv) file."
    end

    def check_count_row(fields, width, row_number)
      if fields.length != width
        raise Invalid, "Row #{row_number + 1} of the count matrix has #{fields.length} columns, but the header has #{width}."
      end

      bad = fields.drop(1).find { |value| !value.match?(/\A\d+\z/) }
      return unless bad

      raise Invalid, "The count matrix must contain raw, non-negative whole-number counts. " \
                     "Row #{row_number + 1} (gene #{fields.first.inspect}) contains #{bad.inspect}. " \
                     "Normalized values or estimated counts (for example from Salmon or kallisto) are not supported."
    end

    def inspect_metadata
      check_size(@metadata_path, "sample sheet")
      table = CSV.read(@metadata_path, col_sep: self.class.delimiter_for(@metadata_path),
                                       headers: true, encoding: "bom|utf-8", skip_blanks: true)
      @metadata_columns = table.headers.map { |header| header.to_s.strip }
      raise Invalid, "The sample sheet is empty." if @metadata_columns.empty?
      raise Invalid, "The sample sheet needs a column named \"#{SAMPLE_COLUMN}\" listing the sample names. Its columns are: #{preview(@metadata_columns)}." unless @metadata_columns.include?(SAMPLE_COLUMN)
      raise Invalid, "The sample sheet has a blank column name." if @metadata_columns.any?(&:blank?)

      duplicates = duplicates_in(@metadata_columns)
      raise Invalid, "The sample sheet has duplicate column names: #{preview(duplicates)}." if duplicates.any?
      raise Invalid, "The sample sheet needs at least one column besides \"#{SAMPLE_COLUMN}\", such as \"condition\"." if condition_columns.empty?

      @metadata_rows = table.map { |row| @metadata_columns.zip(row.fields.map { |value| value.to_s.strip }).to_h }
      raise Invalid, "The sample sheet has no samples." if @metadata_rows.empty?

      blank = @metadata_rows.find { |row| row.values.any?(&:blank?) }
      raise Invalid, "The sample sheet has an empty value for sample #{blank[SAMPLE_COLUMN].presence&.inspect || '(blank)'}. Every sample needs a value in every column." if blank

      duplicates = duplicates_in(@metadata_rows.map { |row| row[SAMPLE_COLUMN] })
      raise Invalid, "The sample sheet lists these samples more than once: #{preview(duplicates)}." if duplicates.any?
    rescue CSV::MalformedCSVError => e
      raise Invalid, "The sample sheet could not be read: #{e.message}"
    rescue ArgumentError, Encoding::InvalidByteSequenceError
      raise Invalid, "The sample sheet is not a readable text file. Please upload a tab-separated (.tsv/.txt) or comma-separated (.csv) file."
    end

    # Every gene ID in the count matrix (the first column), read in full.
    def count_gene_ids
      delimiter = self.class.delimiter_for(@counts_path)
      ids = Set.new
      File.foreach(@counts_path, encoding: "bom|utf-8").with_index do |line, index|
        next if index.zero? || line.strip.empty?

        ids << unquote(line.chomp.delete_suffix("\r").split(delimiter, 2).first.to_s)
      end
      ids
    end

    def inspect_annotations(path)
      check_size(path, "annotation table")
      table = CSV.read(path, col_sep: self.class.delimiter_for(path), headers: true, encoding: "bom|utf-8", skip_blanks: true)
      columns = table.headers.map { |header| header.to_s.strip.downcase }
      missing = ANNOTATION_COLUMNS - columns
      if missing.any?
        raise Invalid, "The annotation table needs columns named #{ANNOTATION_COLUMNS.map(&:inspect).join(' and ')} " \
                       "(missing: #{missing.join(', ')}). Its columns are: #{preview(columns)}."
      end

      gene_index, term_index, source_index = columns.index("gene_id"), columns.index("term"), columns.index("source")
      rows = table.map(&:fields).map { |fields| fields.map { |value| value.to_s.strip } }
        .select { |fields| fields[gene_index].present? && fields[term_index].present? }
      raise Invalid, "The annotation table has no rows with both a gene_id and a term." if rows.empty?

      annotated = rows.map { |fields| fields[gene_index] }.uniq
      counted = count_gene_ids
      matched = annotated.count { |gene| counted.include?(gene) }
      if matched.zero?
        raise Invalid, "None of the annotation table's gene IDs appear in the count matrix (for example #{preview(annotated)}; " \
                       "the count matrix has #{preview(counted.first(LIST_LIMIT))}). The IDs must match exactly."
      end

      sources = rows.map { |fields| source_index && fields[source_index].presence || ANNOTATION_DEFAULT_SOURCE }.uniq
      @annotation_summary = { "rows" => rows.length, "genes_matched" => matched, "genes_in_counts" => counted.size,
                              "sources" => sources }
    rescue CSV::MalformedCSVError => e
      raise Invalid, "The annotation table could not be read: #{e.message}"
    rescue ArgumentError, Encoding::InvalidByteSequenceError
      raise Invalid, "The annotation table is not a readable text file. Please upload a tab-separated (.tsv/.txt) or comma-separated (.csv) file."
    end

    def check_samples_match
      listed = @metadata_rows.map { |row| row[SAMPLE_COLUMN] }
      missing = @sample_ids - listed
      extra = listed - @sample_ids
      return if missing.empty? && extra.empty?

      problems = []
      problems << "in the count matrix but not the sample sheet: #{preview(missing)}" if missing.any?
      problems << "in the sample sheet but not the count matrix: #{preview(extra)}" if extra.any?
      raise Invalid, "The sample names must match exactly between the two files. Samples #{problems.join('; samples ')}."
    end

    def check_size(path, label)
      raise Invalid, "Please upload a #{label}." unless path.file?
      raise Invalid, "The #{label} is empty." if path.size.zero?
      raise Invalid, "The #{label} is larger than #{MAX_FILE_BYTES / 1.megabyte} MB." if path.size > MAX_FILE_BYTES
    end

    def unquote(field)
      field.strip.delete_prefix('"').delete_suffix('"')
    end

    def duplicates_in(values)
      values.tally.select { |_value, count| count > 1 }.keys
    end

    def preview(values)
      shown = values.first(LIST_LIMIT).map(&:inspect).join(", ")
      values.length > LIST_LIMIT ? "#{shown} and #{values.length - LIST_LIMIT} more" : shown
    end
  end
end
