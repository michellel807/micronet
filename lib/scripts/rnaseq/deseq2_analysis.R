# DESeq2 differential expression for MicroNet RNA-seq jobs.
#
# Usage:
#   Rscript deseq2_analysis.R --counts counts.tsv --metadata samples.tsv --config config.json --out DIR
#
# Statistical order (do not rearrange):
#   1. Low-count prefilter on all samples in the model.
#   2. DESeq() on the raw integer counts of that filtered dataset; size factors
#      and dispersions are estimated from every retained gene.
#   3. results() for the configured design: a Wald test for two conditions, or
#      a likelihood ratio test against a reduced model for time courses.
#   4. VST of the same filtered dataset (not of the significant genes).
#   5. Only then select significant genes and subset the transformed matrix.
#
# Writes deseq2_results.tsv, normalized_counts.tsv, size_factors.tsv,
# vst_all.tsv, vst_significant.tsv, and manifest.json to DIR; time-course
# designs also write group_means_vst.tsv. On failure only
# manifest.json is written, with status "failed", and the exit status is 1.

OUTPUT_FILES <- list(
  results = "deseq2_results.tsv",
  normalized_counts = "normalized_counts.tsv",
  size_factors = "size_factors.tsv",
  vst_all = "vst_all.tsv",
  vst_significant = "vst_significant.tsv"
)
GROUP_MEANS_FILE <- "group_means_vst.tsv"
MANIFEST_FILE <- "manifest.json"

# vst() fits its transformation on a subsample of 1000 genes with mean count > 5.
VST_MINIMUM_GENES <- 1000

script_dir <- function() {
  file_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_argument[[1]])))
}

for (helper in c("io.R", "validate.R", "designs.R")) {
  source(file.path(script_dir(), "R", helper))
}

na_reasons <- function(results) {
  reason <- rep("", nrow(results))
  reason[results$baseMean == 0] <- "all_zero"
  reason[reason == "" & is.na(results$pvalue)] <- "cooks_outlier"
  reason[reason == "" & is.na(results$padj)] <- "independent_filtering"
  reason
}

# For time courses, `effects` holds the per-time-point log2 fold changes and a
# post-hoc cutoff applies to the largest of them.
select_significant <- function(results, config, effects = NULL) {
  significant <- !is.na(results$padj) & results$padj < config$alpha
  if (config$lfc_threshold > 0 && config$lfc_test == "posthoc") {
    size <- if (is.null(effects)) abs(results$log2FoldChange) else max_abs(effects)
    significant <- significant & !is.na(size) & size >= config$lfc_threshold
  }
  significant
}

max_abs <- function(effects) {
  apply(abs(effects), 1, function(values) if (all(is.na(values))) NA_real_ else max(values, na.rm = TRUE))
}

# Mean VST value of each gene in each replicate group (condition and time
# point), in long format for trajectory plots and the Gaussian process stage.
group_means <- function(vst_all, model) {
  coldata <- model$coldata
  condition <- if ("condition" %in% colnames(coldata)) as.character(coldata$condition) else rep(NA_character_, nrow(coldata))
  time <- as.character(coldata$time)
  numeric_time <- if (is.null(model$time$numeric_values)) NULL else
    stats::setNames(as.numeric(model$time$numeric_values), model$time$levels)
  keys <- unique(data.frame(condition = condition, time = time, stringsAsFactors = FALSE))
  keys <- keys[order(match(keys$condition, unique(condition)), match(keys$time, model$time$levels)), , drop = FALSE]

  pieces <- lapply(seq_len(nrow(keys)), function(index) {
    members <- (is.na(keys$condition[[index]]) | condition %in% keys$condition[[index]]) & time == keys$time[[index]]
    data.frame(
      gene_id = rownames(vst_all),
      condition = if (is.na(keys$condition[[index]])) "" else keys$condition[[index]],
      time = keys$time[[index]],
      time_value = if (is.null(numeric_time)) NA_real_ else unname(numeric_time[[keys$time[[index]]]]),
      n_samples = sum(members),
      mean_vst = rowMeans(vst_all[, members, drop = FALSE]),
      stringsAsFactors = FALSE, row.names = NULL
    )
  })
  do.call(rbind, pieces)
}

run_analysis <- function(options) {
  config <- normalize_config(read_config(options$config))
  design <- design_for(config$experiment_type)
  counts <- read_count_matrix(options$counts)
  metadata <- align_metadata(read_metadata(options$metadata), colnames(counts), config$sample_column)

  model <- design$prepare(metadata, config)
  counts <- counts[, rownames(model$coldata), drop = FALSE]
  prefilter <- prefilter_genes(counts, model$group, config$prefilter)

  suppressPackageStartupMessages(library(DESeq2))
  dds <- DESeq2::DESeqDataSetFromMatrix(
    countData = counts[prefilter$keep, , drop = FALSE],
    colData = model$coldata,
    design = model$formula
  )
  dds <- if (is.null(model$reduced)) {
    DESeq2::DESeq(dds, quiet = TRUE)
  } else {
    DESeq2::DESeq(dds, test = "LRT", reduced = model$reduced, quiet = TRUE)
  }
  results <- design$test(dds, model, config)
  effects <- design$effects(dds, model)

  normalized <- DESeq2::counts(dds, normalized = TRUE)
  vst_method <- if (sum(rowMeans(normalized) > 5) >= VST_MINIMUM_GENES) "vst" else "varianceStabilizingTransformation"
  transformed <- if (vst_method == "vst") {
    DESeq2::vst(dds, blind = config$vst_blind)
  } else {
    DESeq2::varianceStabilizingTransformation(dds, blind = config$vst_blind)
  }
  vst_all <- SummarizedExperiment::assay(transformed)
  stopifnot(identical(rownames(results), rownames(vst_all)))

  significant <- select_significant(results, config, effects)
  vst_significant <- vst_all[significant, , drop = FALSE]

  reasons <- na_reasons(results)
  results_table <- data.frame(
    gene_id = rownames(results),
    baseMean = results$baseMean,
    stringsAsFactors = FALSE
  )
  if (is.null(effects)) {
    results_table$log2FoldChange <- results$log2FoldChange
    results_table$lfcSE <- results$lfcSE
  }
  results_table$stat <- results$stat
  results_table$pvalue <- results$pvalue
  results_table$padj <- results$padj
  results_table$significant <- significant
  results_table$padj_na_reason <- reasons
  if (!is.null(effects)) {
    # A likelihood ratio test has no single fold change; report the change at each time point instead.
    results_table$max_abs_log2FC <- max_abs(effects)
    results_table <- cbind(results_table, as.data.frame(effects, optional = TRUE), stringsAsFactors = FALSE)
  }
  results_table <- results_table[order(is.na(results_table$padj), results_table$padj, results_table$pvalue), , drop = FALSE]

  size_factors <- data.frame(sample = colnames(dds), stringsAsFactors = FALSE)
  if ("condition" %in% colnames(model$coldata)) size_factors$condition <- as.character(dds$condition)
  if ("time" %in% colnames(model$coldata)) size_factors$time <- as.character(dds$time)
  size_factors$size_factor <- DESeq2::sizeFactors(dds)

  outputs <- OUTPUT_FILES
  means <- NULL
  if (!is.null(model$time)) {
    means <- group_means(vst_all, model)
    outputs$group_means <- GROUP_MEANS_FILE
  }

  manifest <- list(
    status = "completed",
    schema_version = 1L,
    experiment_type = config$experiment_type,
    design = model$description,
    test = if (is.null(model$reduced)) "wald" else "likelihood_ratio",
    question = model$question,
    contrast = if (is.null(model$contrast)) NULL else list(
      variable = config$condition_column,
      test_level = config$test_level,
      reference_level = config$reference_level,
      log2_fold_change = sprintf("log2(%s / %s)", config$test_level, config$reference_level)
    ),
    time = model$time,
    subset = model$subset,
    effect_columns = if (is.null(effects)) NULL else I(colnames(effects)),
    parameters = utils::modifyList(config, list(covariates = I(config$covariates))),
    samples = list(in_input = nrow(metadata), in_model = ncol(dds), per_group = model$groups),
    genes = list(
      in_input = nrow(counts),
      passed_prefilter = nrow(dds),
      prefilter_min_samples = prefilter$min_samples,
      tested = sum(!is.na(results$pvalue)),
      padj_na = list(
        cooks_outlier = sum(reasons == "cooks_outlier"),
        independent_filtering = sum(reasons == "independent_filtering")
      ),
      significant = sum(significant),
      # Only a two-group comparison has one direction per gene.
      significant_up = if (is.null(effects)) sum(significant & results$log2FoldChange > 0) else NULL,
      significant_down = if (is.null(effects)) sum(significant & results$log2FoldChange < 0) else NULL
    ),
    vst_method = vst_method,
    outputs = outputs,
    versions = list(R = R.version.string, DESeq2 = as.character(utils::packageVersion("DESeq2")))
  )

  # Every computation succeeded; only now write the result files.
  write_tsv(results_table, file.path(options$out, OUTPUT_FILES$results))
  write_tsv(matrix_table(normalized), file.path(options$out, OUTPUT_FILES$normalized_counts))
  write_tsv(size_factors, file.path(options$out, OUTPUT_FILES$size_factors))
  write_tsv(matrix_table(vst_all), file.path(options$out, OUTPUT_FILES$vst_all))
  write_tsv(matrix_table(vst_significant), file.path(options$out, OUTPUT_FILES$vst_significant))
  if (!is.null(means)) write_tsv(means, file.path(options$out, GROUP_MEANS_FILE))
  manifest
}

main <- function(args) {
  options <- parse_args(args, c("counts", "metadata", "config", "out"))
  dir.create(options$out, recursive = TRUE, showWarnings = FALSE)
  # Never leave results from an earlier run beside a new failure.
  unlink(file.path(options$out, c(unlist(OUTPUT_FILES), GROUP_MEANS_FILE, MANIFEST_FILE)))

  warnings_seen <- character(0)
  failure <- function(type, message) list(status = "failed", error_type = type, message = message)
  manifest <- withCallingHandlers(
    tryCatch(
      run_analysis(options),
      micronet_input_error = function(e) failure("input_error", conditionMessage(e)),
      error = function(e) failure("internal_error", conditionMessage(e))
    ),
    warning = function(w) {
      warnings_seen <<- c(warnings_seen, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  manifest$warnings <- I(unique(warnings_seen))
  write_json(manifest, file.path(options$out, MANIFEST_FILE))

  if (manifest$status != "completed") {
    message(sprintf("%s: %s", manifest$error_type, manifest$message))
    quit(save = "no", status = 1)
  }
}

main(commandArgs(trailingOnly = TRUE))
