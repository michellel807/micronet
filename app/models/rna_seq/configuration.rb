module RnaSeq
  # The settings for one RNA-seq job, saved in Job#analysis_config. The
  # statistical settings are passed unchanged to deseq2_analysis.R, which
  # validates their values; this class checks only names and input files.
  # Gene clustering settings (time courses only) and the Gaussian process test
  # settings (condition_time_gp only) are kept apart from the DESeq2 settings,
  # which the R script rejects when it does not know them.
  class Configuration
    class Invalid < StandardError; end

    INPUT_EXTENSIONS = %w[.csv .tsv .txt].freeze
    DESEQ2_SETTINGS = %w[
      schema_version experiment_type sample_column condition_column reference_level test_level
      time_column subset_level sampling_design replicate_column
      covariates samples_in_model min_replicates prefilter alpha lfc_threshold lfc_test vst_blind
    ].freeze
    EXPERIMENT_TYPES = {
      "two_condition" => "Two-condition differential expression",
      "time_course" => "Time course",
      "condition_by_time" => "Condition-by-time interaction",
      "condition_time_gp" => "Compare conditions over time (Gaussian process test)"
    }.freeze
    # DESeq2 only normalizes; gene clusters are compared with a B-GREAT-style
    # Gaussian process test (lib/scripts/rnaseq/gp_condition_test.py).
    GP_TYPE = "condition_time_gp".freeze
    TIME_TYPES = %w[time_course condition_by_time condition_time_gp].freeze
    # Types that compare a test condition with a reference condition.
    COMPARISON_TYPES = %w[two_condition condition_by_time condition_time_gp].freeze
    # How the samples were collected decides which labels the test may shuffle.
    # It is always the user's answer: there is no default.
    SAMPLING_DESIGNS = {
      "independent" => "Each sample is a separate culture, harvested once",
      "repeated" => "Each culture was sampled at several time points"
    }.freeze
    # Shown in emails when a setting is omitted; DEFAULT_CONFIG in
    # lib/scripts/rnaseq/R/validate.R is what the analysis actually uses.
    DISPLAY_DEFAULTS = { "experiment_type" => "two_condition", "condition_column" => "condition", "time_column" => "time", "alpha" => 0.05, "lfc_threshold" => 0 }.freeze
    # The optional settings on the web form, pre-filled with the R defaults.
    # Values equal to these are left out of the saved settings so the R
    # defaults stay in charge of them.
    ADVANCED_DEFAULTS = {
      "alpha" => 0.05, "lfc_threshold" => 0.0, "lfc_test" => "posthoc",
      "samples_in_model" => "all", "covariates" => []
    }.freeze
    LFC_TESTS = { "posthoc" => "Filter after testing", "deseq2" => "Test against the cutoff (DESeq2 lfcThreshold)" }.freeze
    SAMPLES_IN_MODEL = { "all" => "All samples", "contrast_only" => "Only the two compared groups" }.freeze
    # Matches MIN_CLUSTERS and MAX_CLUSTERS in lib/scripts/rnaseq/cluster_genes.py.
    CLUSTER_COUNTS = (2..10).freeze
    CLUSTERING_SETTINGS = %w[cluster_genes clusters silhouette_baseline].freeze
    # treatment_start absent: treated from the start. Match gp_condition_test.py
    # and cluster_genes.py.
    GP_TEST_SETTINGS = %w[treatment_start variable_percent permutations].freeze
    DEFAULT_PERMUTATIONS = 999
    PERMUTATION_COUNTS = (99..9999).freeze
    AUTOMATIC_GENES = 1000

    attr_reader :counts_file, :metadata_file, :annotation_file, :original_filenames, :deseq2, :clustering, :gp_test

    def self.from_h(hash)
      hash = hash.to_h.deep_stringify_keys
      new(counts_file: hash["counts_file"], metadata_file: hash["metadata_file"], annotation_file: hash["annotation_file"],
          deseq2: hash["deseq2"], original_filenames: hash["original_filenames"], clustering: hash["clustering"],
          gp_test: hash["gp_test"])
    end

    def initialize(counts_file:, metadata_file:, deseq2:, original_filenames: nil, clustering: nil, annotation_file: nil,
                   gp_test: nil)
      @counts_file = counts_file.to_s
      @metadata_file = metadata_file.to_s
      @annotation_file = annotation_file.presence&.to_s
      @deseq2 = deseq2.to_h.deep_stringify_keys
      @original_filenames = (original_filenames || {}).to_h.stringify_keys
      @clustering = clustering.to_h.stringify_keys.compact
      @gp_test = gp_test.to_h.stringify_keys.compact
      validate!
    end

    def to_h
      hash = { "counts_file" => counts_file, "metadata_file" => metadata_file,
               "original_filenames" => original_filenames, "deseq2" => deseq2 }
      hash["clustering"] = clustering if clustering.present?
      hash["gp_test"] = gp_test if gp_test.present?
      hash["annotation_file"] = annotation_file if annotation_file
      hash
    end

    def input_files
      [counts_file, metadata_file, annotation_file].compact
    end

    # The number of gene clusters the user chose, or nil to choose it from the data.
    def cluster_count
      clustering["clusters"]
    end

    # Time courses cluster their significant genes unless the user turned it off
    # (stored as "cluster_genes" => false).
    def cluster_genes?
      time_course? && (gp_test? || clustering["cluster_genes"] != false)
    end

    def gp_test?
      experiment_type == GP_TYPE
    end

    # The time the treatment was added, or nil when the samples were treated from the start.
    def treatment_start
      gp_test["treatment_start"]
    end

    # The percent of the most variable genes to cluster, or nil for automatic.
    def variable_percent
      gp_test["variable_percent"]
    end

    def permutations
      gp_test.fetch("permutations", DEFAULT_PERMUTATIONS)
    end

    # Whether to compare the clustering's silhouette with a shuffled-data baseline.
    def silhouette_baseline?
      clustering["silhouette_baseline"] == true
    end

    def inputs_present?(directories)
      input_files.all? do |name|
        path = directories.rnaseq_input_dir.join(name)
        path.file? && !path.symlink?
      end
    end

    def experiment_type
      deseq2["experiment_type"].presence || DISPLAY_DEFAULTS["experiment_type"]
    end

    def time_course?
      TIME_TYPES.include?(experiment_type)
    end

    def write_deseq2_config(path)
      File.write(path, JSON.pretty_generate(deseq2))
    end

    # Saved as Job#submission_options for the confirmation and failure emails.
    def summary
      settings = DISPLAY_DEFAULTS.merge(deseq2)
      return gp_summary(settings) if gp_test?

      significance = "adjusted p-value < #{settings['alpha']}"
      if settings["lfc_threshold"].to_f.positive?
        size = time_course? ? "largest |log2 fold change| across time points" : "|log2 fold change|"
        significance += " and #{size} ≥ #{settings['lfc_threshold']}"
      end
      {
        "Analysis" => "RNA-seq: #{EXPERIMENT_TYPES.fetch(settings['experiment_type'], settings['experiment_type'])} (DESeq2)",
        "Comparison" => comparison_description(settings),
        "Covariates" => Array(settings["covariates"]).presence&.join(", ") || "None",
        "Significance" => significance,
        **(time_course? ? { "Gene clusters" => cluster_description } : {}),
        "Functional enrichment" => enrichment_description,
        "Uploaded Files" => uploaded_files
      }
    end

    def treatment_description
      return "Before the first sample (treated from the start)" if treatment_start.nil?

      "Added at time #{format_number(treatment_start)}; samples up to then are a shared baseline"
    end

    def sampling_description
      design = deseq2["sampling_design"]
      text = SAMPLING_DESIGNS.fetch(design, design.to_s)
      design == "repeated" ? "#{text} (cultures in column #{deseq2['replicate_column']})" : text
    end

    def gene_selection_description
      return "The top #{format_number(variable_percent)}% most variable genes" if variable_percent

      "The #{AUTOMATIC_GENES} most variable genes (or half of the genes, if that is fewer)"
    end

    def enrichment_description
      return "Not run (no annotation table uploaded)" unless annotation_file

      "Fisher's exact test against #{original_filenames.fetch('annotations', annotation_file)}"
    end

    def cluster_description
      return "Not clustered (turned off)" unless cluster_genes?

      description = cluster_count ? "#{cluster_count} (set by you)" : "Number chosen automatically from the data"
      silhouette_baseline? ? "#{description}; silhouette checked against a shuffled baseline" : description
    end

    private

    def gp_summary(settings)
      {
        "Analysis" => "RNA-seq: #{EXPERIMENT_TYPES[GP_TYPE]} (normalized with DESeq2; B-GREAT-style test of each gene cluster)",
        "Comparison" => comparison_description(settings),
        "Treatment" => treatment_description,
        "Sampling" => sampling_description,
        "Genes clustered" => gene_selection_description,
        "Covariates" => Array(settings["covariates"]).presence&.join(", ") || "None",
        "Significance" => "cluster q-value < #{settings['alpha']} (#{permutations} label permutations)",
        "Gene clusters" => cluster_description,
        "Functional enrichment" => enrichment_description,
        "Uploaded Files" => uploaded_files
      }
    end

    def uploaded_files
      {
        "Count Matrix" => [original_filenames.fetch("counts", counts_file)],
        "Sample Metadata" => [original_filenames.fetch("metadata", metadata_file)],
        **(annotation_file ? { "Gene Annotations" => [original_filenames.fetch("annotations", annotation_file)] } : {})
      }
    end

    def format_number(value)
      value.to_f == value.to_i ? value.to_i.to_s : value.to_s
    end

    def comparison_description(settings)
      case settings["experiment_type"]
      when "time_course"
        samples = settings["subset_level"].present? ? "samples with #{settings['condition_column']} = #{settings['subset_level']}" : "all samples"
        "Change over time (column #{settings['time_column']}), #{samples}"
      when "condition_by_time"
        "How #{settings['test_level']} vs #{settings['reference_level']} (reference) changes over time " \
          "(columns #{settings['condition_column']} and #{settings['time_column']})"
      when GP_TYPE
        "Whether each gene cluster follows a different course over time in #{settings['test_level']} than in " \
          "#{settings['reference_level']} (reference) (columns #{settings['condition_column']} and #{settings['time_column']})"
      else
        "#{settings['test_level']} vs #{settings['reference_level']} (reference), column #{settings['condition_column']}"
      end
    end

    def validate!
      input_files.each do |name|
        unless name == File.basename(name) && INPUT_EXTENSIONS.include?(File.extname(name).downcase)
          raise Invalid, "Input files must be stored as .csv, .tsv or .txt names without directories: #{name.inspect}"
        end
      end
      raise Invalid, "The count matrix, sample metadata and annotations must be different files" if input_files.uniq.length < input_files.length

      unknown = deseq2.keys - DESEQ2_SETTINGS
      raise Invalid, "Unknown RNA-seq settings: #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "Unknown RNA-seq experiment type: #{experiment_type}" unless EXPERIMENT_TYPES.key?(experiment_type)
      if COMPARISON_TYPES.include?(experiment_type)
        %w[reference_level test_level].each do |key|
          raise Invalid, "The RNA-seq #{key.tr('_', ' ')} is required" if deseq2[key].blank?
        end
      end
      validate_sampling!
      validate_clustering!
      validate_gp_test!
    end

    def validate_sampling!
      design, column = deseq2.values_at("sampling_design", "replicate_column")
      unless gp_test?
        raise Invalid, "The sampling design applies only to the Gaussian process comparison" if design || column
        return
      end
      unless SAMPLING_DESIGNS.key?(design)
        raise Invalid, "Please say how the samples were collected: #{SAMPLING_DESIGNS.values.join(', or ').downcase}"
      end
      raise Invalid, "Please choose the sample sheet column that names each culture" if design == "repeated" && column.blank?
      raise Invalid, "A culture column applies only when cultures were sampled repeatedly" if design == "independent" && column
    end

    def validate_gp_test!
      unknown = gp_test.keys - GP_TEST_SETTINGS
      raise Invalid, "Unknown Gaussian process test settings: #{unknown.join(', ')}" if unknown.any?
      return if gp_test.empty?
      raise Invalid, "The Gaussian process test settings apply only to the Gaussian process comparison" unless gp_test?

      if gp_test.key?("treatment_start") && !treatment_start.is_a?(Numeric)
        raise Invalid, "The treatment time must be a number"
      end
      if gp_test.key?("variable_percent") && !(variable_percent.is_a?(Numeric) && variable_percent.positive? && variable_percent <= 100)
        raise Invalid, "The percent of most variable genes must be more than 0 and at most 100"
      end
      return unless gp_test.key?("permutations")

      unless permutations.is_a?(Integer) && PERMUTATION_COUNTS.cover?(permutations)
        raise Invalid, "The number of permutations must be a whole number from #{PERMUTATION_COUNTS.min} to #{PERMUTATION_COUNTS.max}"
      end
    end

    def validate_clustering!
      unknown = clustering.keys - CLUSTERING_SETTINGS
      raise Invalid, "Unknown gene clustering settings: #{unknown.join(', ')}" if unknown.any?
      if clustering.key?("cluster_genes")
        raise Invalid, "The cluster genes setting must be false when present" unless clustering["cluster_genes"] == false
        raise Invalid, "Gene clustering applies only to time-course analyses" unless time_course?
        raise Invalid, "The Gaussian process comparison tests gene clusters, so clustering cannot be turned off" if gp_test?
        raise Invalid, "Clustering settings cannot be combined with turning clustering off" if clustering.size > 1
      end
      if clustering.key?("silhouette_baseline")
        raise Invalid, "The silhouette baseline setting must be true when present" unless clustering["silhouette_baseline"] == true
        raise Invalid, "Gene clustering applies only to time-course analyses" unless time_course?
      end
      return if cluster_count.nil?

      raise Invalid, "Gene clustering applies only to time-course analyses" unless time_course?
      unless cluster_count.is_a?(Integer) && CLUSTER_COUNTS.cover?(cluster_count)
        raise Invalid, "The number of gene clusters must be a whole number from #{CLUSTER_COUNTS.min} to #{CLUSTER_COUNTS.max}"
      end
    end
  end
end
