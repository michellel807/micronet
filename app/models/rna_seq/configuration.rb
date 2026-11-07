module RnaSeq
  # The settings for one RNA-seq job, saved in Job#analysis_config. The
  # statistical settings are passed unchanged to deseq2_analysis.R, which
  # validates their values; this class checks only names and input files.
  class Configuration
    class Invalid < StandardError; end

    INPUT_EXTENSIONS = %w[.csv .tsv .txt].freeze
    DESEQ2_SETTINGS = %w[
      schema_version experiment_type sample_column condition_column reference_level test_level
      covariates samples_in_model min_replicates prefilter alpha lfc_threshold lfc_test vst_blind
    ].freeze
    EXPERIMENT_TYPES = { "two_condition" => "Two-condition differential expression" }.freeze
    # Shown in emails when a setting is omitted; DEFAULT_CONFIG in
    # lib/scripts/rnaseq/R/validate.R is what the analysis actually uses.
    DISPLAY_DEFAULTS = { "experiment_type" => "two_condition", "condition_column" => "condition", "alpha" => 0.05, "lfc_threshold" => 0 }.freeze

    attr_reader :counts_file, :metadata_file, :original_filenames, :deseq2

    def self.from_h(hash)
      hash = hash.to_h.deep_stringify_keys
      new(counts_file: hash["counts_file"], metadata_file: hash["metadata_file"],
          deseq2: hash["deseq2"], original_filenames: hash["original_filenames"])
    end

    def initialize(counts_file:, metadata_file:, deseq2:, original_filenames: nil)
      @counts_file = counts_file.to_s
      @metadata_file = metadata_file.to_s
      @deseq2 = deseq2.to_h.deep_stringify_keys
      @original_filenames = (original_filenames || {}).to_h.stringify_keys
      validate!
    end

    def to_h
      { "counts_file" => counts_file, "metadata_file" => metadata_file,
        "original_filenames" => original_filenames, "deseq2" => deseq2 }
    end

    def inputs_present?(directories)
      [counts_file, metadata_file].all? do |name|
        path = directories.rnaseq_input_dir.join(name)
        path.file? && !path.symlink?
      end
    end

    def write_deseq2_config(path)
      File.write(path, JSON.pretty_generate(deseq2))
    end

    # Saved as Job#submission_options for the confirmation and failure emails.
    def summary
      settings = DISPLAY_DEFAULTS.merge(deseq2)
      significance = "adjusted p-value < #{settings['alpha']}"
      significance += " and |log2 fold change| ≥ #{settings['lfc_threshold']}" if settings["lfc_threshold"].to_f.positive?
      {
        "Analysis" => "RNA-seq: #{EXPERIMENT_TYPES.fetch(settings['experiment_type'], settings['experiment_type'])} (DESeq2)",
        "Comparison" => "#{settings['test_level']} vs #{settings['reference_level']} (reference), column #{settings['condition_column']}",
        "Covariates" => Array(settings["covariates"]).presence&.join(", ") || "None",
        "Significance" => significance,
        "Uploaded Files" => {
          "Count Matrix" => [original_filenames.fetch("counts", counts_file)],
          "Sample Metadata" => [original_filenames.fetch("metadata", metadata_file)]
        }
      }
    end

    private

    def validate!
      [counts_file, metadata_file].each do |name|
        unless name == File.basename(name) && INPUT_EXTENSIONS.include?(File.extname(name).downcase)
          raise Invalid, "Input files must be stored as .csv, .tsv or .txt names without directories: #{name.inspect}"
        end
      end
      raise Invalid, "The count matrix and sample metadata must be different files" if counts_file == metadata_file

      unknown = deseq2.keys - DESEQ2_SETTINGS
      raise Invalid, "Unknown RNA-seq settings: #{unknown.join(', ')}" if unknown.any?
      %w[reference_level test_level].each do |key|
        raise Invalid, "The RNA-seq #{key.tr('_', ' ')} is required" if deseq2[key].blank?
      end
    end
  end
end
