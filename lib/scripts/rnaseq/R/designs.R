# Experiment designs. Each entry builds the DESeq2 model for one experiment type:
#   prepare(metadata, config) -> list(coldata, formula, groups, description, contrast)
#   test(dds, model, config)  -> DESeqResults for every tested gene
# The shared pipeline in deseq2_analysis.R handles normalization, VST, and
# significant-gene selection identically for every design.

PLANNED_DESIGNS <- c("multi_condition", "time_course", "condition_by_time")

# Metadata column names are user-supplied and may contain spaces or symbols, so
# the model uses safe internal names (covariate_1, ..., condition).
model_frame <- function(metadata, config) {
  condition <- require_column(metadata, config$condition_column, "condition")
  coldata <- data.frame(row.names = rownames(metadata))

  for (index in seq_along(config$covariates)) {
    covariate <- config$covariates[[index]]
    if (covariate %in% c(config$sample_column, config$condition_column)) {
      stop_input("The covariate '%s' cannot also be the sample or condition column.", covariate)
    }
    values <- require_column(metadata, covariate, "covariate")
    if (length(unique(values)) < 2) stop_input("The covariate '%s' has only one value, so it cannot be modeled.", covariate)
    coldata[[sprintf("covariate_%d", index)]] <- factor(values)
  }

  coldata$condition <- stats::relevel(factor(condition), ref = config$reference_level)
  terms <- c(setdiff(colnames(coldata), "condition"), "condition")
  formula <- stats::as.formula(paste("~", paste(terms, collapse = " + ")))

  design_matrix <- stats::model.matrix(formula, coldata)
  if (qr(design_matrix)$rank < ncol(design_matrix)) {
    stop_input("The design cannot be estimated because the condition is confounded with a covariate (for example, every batch contains only one condition).")
  }
  if (nrow(design_matrix) <= ncol(design_matrix)) {
    stop_input("There are not enough samples to estimate the design (%d samples for %d coefficients).", nrow(design_matrix), ncol(design_matrix))
  }
  list(
    coldata = coldata,
    formula = formula,
    description = paste("~", paste(c(config$covariates, config$condition_column), collapse = " + "))
  )
}

prepare_two_condition <- function(metadata, config) {
  if (config$condition_column == config$sample_column) {
    stop_input("The condition column must be different from the sample column.")
  }
  reference <- config$reference_level
  test <- config$test_level
  if (reference == test) stop_input("The reference and test conditions must be different.")

  condition <- require_column(metadata, config$condition_column, "condition")
  absent <- setdiff(c(reference, test), condition)
  if (length(absent) > 0) {
    stop_input("Condition levels not found in column '%s': %s. Available levels: %s.",
               config$condition_column, preview(absent), preview(sort(unique(condition)), 20))
  }
  if (config$samples_in_model == "contrast_only") {
    metadata <- metadata[condition %in% c(reference, test), , drop = FALSE]
  }

  groups <- table(metadata[[config$condition_column]])
  for (level in c(reference, test)) {
    if (groups[[level]] < config$min_replicates) {
      stop_input("The '%s' group has %d replicate(s); at least %d biological replicates per compared group are required.",
                 level, groups[[level]], config$min_replicates)
    }
  }

  model <- model_frame(metadata, config)
  model$groups <- as.list(stats::setNames(as.integer(groups), names(groups)))
  model$contrast <- c("condition", test, reference)
  model
}

test_two_condition <- function(dds, model, config) {
  arguments <- list(dds, contrast = model$contrast, alpha = config$alpha)
  if (config$lfc_threshold > 0 && config$lfc_test == "deseq2") {
    arguments$lfcThreshold <- config$lfc_threshold
    arguments$altHypothesis <- "greaterAbs"
  }
  do.call(DESeq2::results, arguments)
}

DESIGNS <- list(
  two_condition = list(prepare = prepare_two_condition, test = test_two_condition)
)

design_for <- function(experiment_type) {
  if (experiment_type %in% names(DESIGNS)) return(DESIGNS[[experiment_type]])
  if (experiment_type %in% PLANNED_DESIGNS) {
    stop_input("The '%s' experiment type is not supported yet. Supported types: %s.",
               experiment_type, paste(names(DESIGNS), collapse = ", "))
  }
  stop_input("Unknown experiment type '%s'. Supported types: %s.", experiment_type, paste(names(DESIGNS), collapse = ", "))
}
