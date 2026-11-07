# Validation of the analysis configuration, count matrix, and sample metadata.

DEFAULT_CONFIG <- list(
  schema_version = 1L,
  experiment_type = "two_condition",
  sample_column = "sample",
  condition_column = "condition",
  reference_level = NULL,
  test_level = NULL,
  covariates = character(0),
  # "all" keeps every sample in the model so dispersion is estimated from all
  # groups; "contrast_only" drops samples outside the two compared levels.
  samples_in_model = "all",
  min_replicates = 2L,
  prefilter = list(min_count = 10L, min_samples = "smallest_group"),
  alpha = 0.05,
  lfc_threshold = 0,
  # "posthoc" filters |log2FC| after testing; "deseq2" tests H0: |log2FC| <= threshold.
  lfc_test = "posthoc",
  vst_blind = FALSE
)

scalar_string <- function(value, name) {
  if (!is.character(value) || length(value) != 1 || is.na(value) || !nzchar(trimws(value))) {
    stop_input("Configuration value '%s' must be a non-empty text value.", name)
  }
  trimws(value)
}

scalar_number <- function(value, name, minimum, integer = FALSE) {
  if (!is.numeric(value) || length(value) != 1 || is.na(value) || value < minimum ||
      (integer && value != round(value))) {
    kind <- if (integer) "a whole number" else "a number"
    stop_input("Configuration value '%s' must be %s of at least %s.", name, kind, minimum)
  }
  value
}

choice <- function(value, name, choices) {
  value <- scalar_string(value, name)
  if (!value %in% choices) {
    stop_input("Configuration value '%s' must be one of: %s.", name, paste(choices, collapse = ", "))
  }
  value
}

normalize_config <- function(raw) {
  if (!is.list(raw)) stop_input("The analysis configuration must be a JSON object.")
  unknown <- setdiff(names(raw), names(DEFAULT_CONFIG))
  if (length(unknown) > 0) stop_input("Unknown configuration settings: %s.", preview(unknown))
  unknown <- setdiff(names(raw$prefilter), names(DEFAULT_CONFIG$prefilter))
  if (length(unknown) > 0) stop_input("Unknown prefilter settings: %s.", preview(unknown))

  config <- utils::modifyList(DEFAULT_CONFIG, raw)
  if (!identical(as.integer(config$schema_version), 1L)) {
    stop_input("Unsupported configuration schema_version: %s.", preview(config$schema_version))
  }
  config$schema_version <- 1L
  config$experiment_type <- scalar_string(config$experiment_type, "experiment_type")
  config$sample_column <- scalar_string(config$sample_column, "sample_column")
  config$condition_column <- scalar_string(config$condition_column, "condition_column")
  if (is.null(config$reference_level)) stop_input("Configuration value 'reference_level' is required.")
  if (is.null(config$test_level)) stop_input("Configuration value 'test_level' is required.")
  config$reference_level <- scalar_string(config$reference_level, "reference_level")
  config$test_level <- scalar_string(config$test_level, "test_level")
  config$covariates <- trimws(as.character(unlist(config$covariates)))
  config$samples_in_model <- choice(config$samples_in_model, "samples_in_model", c("all", "contrast_only"))
  config$min_replicates <- as.integer(scalar_number(config$min_replicates, "min_replicates", 2, integer = TRUE))

  config$prefilter$min_count <- as.integer(scalar_number(config$prefilter$min_count, "prefilter.min_count", 0, integer = TRUE))
  min_samples <- config$prefilter$min_samples
  if (!identical(min_samples, "smallest_group")) {
    config$prefilter$min_samples <- as.integer(scalar_number(min_samples, "prefilter.min_samples", 1, integer = TRUE))
  }

  config$alpha <- scalar_number(config$alpha, "alpha", 0)
  if (config$alpha <= 0 || config$alpha >= 1) stop_input("Configuration value 'alpha' must be between 0 and 1.")
  config$lfc_threshold <- scalar_number(config$lfc_threshold, "lfc_threshold", 0)
  config$lfc_test <- choice(config$lfc_test, "lfc_test", c("posthoc", "deseq2"))
  if (!is.logical(config$vst_blind) || length(config$vst_blind) != 1 || is.na(config$vst_blind)) {
    stop_input("Configuration value 'vst_blind' must be true or false.")
  }
  config
}

# Returns an integer matrix with gene IDs as row names and samples as columns.
read_count_matrix <- function(path) {
  table <- read_delimited(path, "count matrix", keep_row_names = TRUE)
  if (ncol(table) < 2) {
    stop_input("The count matrix needs a gene ID column followed by one column per sample.")
  }

  gene_ids <- trimws(table[[1]])
  if (any(!nzchar(gene_ids))) stop_input("The count matrix has %d rows without a gene ID.", sum(!nzchar(gene_ids)))
  duplicated_ids <- unique(gene_ids[duplicated(gene_ids)])
  if (length(duplicated_ids) > 0) stop_input("Duplicate gene IDs in the count matrix: %s.", preview(duplicated_ids))

  samples <- trimws(colnames(table)[-1])
  if (any(!nzchar(samples))) stop_input("Every sample column in the count matrix needs a name in the header row.")
  duplicated_samples <- unique(samples[duplicated(samples)])
  if (length(duplicated_samples) > 0) stop_input("Duplicate sample names in the count matrix: %s.", preview(duplicated_samples))

  text <- as.matrix(table[, -1, drop = FALSE])
  text[is.na(text)] <- ""
  numbers <- suppressWarnings(as.numeric(text))
  dim(numbers) <- dim(text)

  locate <- function(mask) {
    cell <- which(mask, arr.ind = TRUE)[1, ]
    sprintf("gene %s, sample %s", gene_ids[cell[[1]]], samples[cell[[2]]])
  }
  missing <- text == "" | toupper(text) %in% c("NA", "NAN")
  if (any(missing)) {
    stop_input("The count matrix has %d missing values (first at %s). Use 0 for genes with no reads.", sum(missing), locate(missing))
  }
  if (anyNA(numbers)) stop_input("A count matrix value is not a number (at %s).", locate(is.na(numbers)))
  if (any(!is.finite(numbers))) stop_input("A count matrix value is infinite (at %s).", locate(!is.finite(numbers)))
  if (any(numbers < 0)) stop_input("Count matrix values cannot be negative (found at %s).", locate(numbers < 0))
  fractional <- numbers != round(numbers)
  if (any(fractional)) {
    stop_input(paste(
      "Count matrix values must be whole numbers (raw read counts); found %s at %s.",
      "Estimated counts from tools such as Salmon or kallisto must be summarized with tximport or rounded first."
    ), format(numbers[fractional][[1]]), locate(fractional))
  }
  if (any(numbers > .Machine$integer.max)) stop_input("A count matrix value is too large (at %s).", locate(numbers > .Machine$integer.max))

  storage.mode(numbers) <- "integer"
  dimnames(numbers) <- list(gene_ids, samples)
  empty <- samples[colSums(numbers) == 0]
  if (length(empty) > 0) stop_input("These samples have no counts at all: %s.", preview(empty))
  numbers
}

read_metadata <- function(path) {
  table <- read_delimited(path, "sample metadata")
  colnames(table) <- trimws(colnames(table))
  duplicated_columns <- unique(colnames(table)[duplicated(colnames(table))])
  if (length(duplicated_columns) > 0) stop_input("Duplicate column names in the sample metadata: %s.", preview(duplicated_columns))
  table[] <- lapply(table, function(column) {
    column <- trimws(column)
    column[is.na(column) | toupper(column) %in% c("NA", "NAN")] <- ""
    column
  })
  table
}

require_column <- function(metadata, column, role) {
  if (!column %in% colnames(metadata)) {
    stop_input("The %s column '%s' was not found in the sample metadata. Available columns: %s.",
               role, column, preview(colnames(metadata), 20))
  }
  values <- metadata[[column]]
  if (any(!nzchar(values))) {
    stop_input("The %s column '%s' is blank for samples: %s.", role, column, preview(rownames(metadata)[!nzchar(values)]))
  }
  values
}

# Reorders metadata rows to match the count matrix columns, which DESeq2 requires.
align_metadata <- function(metadata, samples, sample_column) {
  if (!sample_column %in% colnames(metadata)) {
    stop_input("The sample column '%s' was not found in the sample metadata. Available columns: %s.",
               sample_column, preview(colnames(metadata), 20))
  }
  ids <- metadata[[sample_column]]
  if (any(!nzchar(ids))) stop_input("The sample column '%s' has blank entries.", sample_column)
  duplicated_ids <- unique(ids[duplicated(ids)])
  if (length(duplicated_ids) > 0) stop_input("Duplicate sample names in the sample metadata: %s.", preview(duplicated_ids))

  not_described <- setdiff(samples, ids)
  not_counted <- setdiff(ids, samples)
  if (length(not_described) > 0 || length(not_counted) > 0) {
    problems <- c(
      if (length(not_described) > 0) sprintf("count matrix samples not found in the metadata: %s", preview(not_described)),
      if (length(not_counted) > 0) sprintf("metadata samples not found in the count matrix: %s", preview(not_counted))
    )
    stop_input("The sample names in the count matrix and metadata must match exactly (%s).", paste(problems, collapse = "; "))
  }

  metadata <- metadata[match(samples, ids), , drop = FALSE]
  rownames(metadata) <- samples
  metadata
}

# Low-count prefilter recommended in the DESeq2 vignette: keep genes with at
# least min_count reads in at least min_samples samples (by default, the size
# of the smallest group in the model).
prefilter_genes <- function(counts, condition, prefilter) {
  min_samples <- prefilter$min_samples
  if (identical(min_samples, "smallest_group")) min_samples <- min(table(condition))
  if (min_samples > ncol(counts)) {
    stop_input("prefilter.min_samples (%d) is larger than the number of samples in the model (%d).", min_samples, ncol(counts))
  }
  keep <- rowSums(counts >= prefilter$min_count) >= min_samples
  if (!any(keep)) stop_input("No genes passed the low-count filter (at least %d reads in at least %d samples).", prefilter$min_count, min_samples)
  # Median-of-ratios size factors need genes that are nonzero in every sample.
  if (!any(rowSums(counts[keep, , drop = FALSE] == 0) == 0)) {
    stop_input("Every gene that passed the low-count filter has a zero in at least one sample, so normalization factors cannot be estimated.")
  }
  list(keep = keep, min_samples = as.integer(min_samples))
}
