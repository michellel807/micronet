# Experiment designs. Each entry builds the DESeq2 model for one experiment type:
#   prepare(metadata, config) -> list(coldata, formula, groups, group, description,
#                                     question, [contrast], [reduced], [time])
#   test(dds, model, config)  -> DESeqResults for every tested gene
#   effects(dds, model)       -> genes x named log2 fold changes reported beside
#                                the test, or NULL when results() already has one
# model$group is the factor that defines replicate groups (used by the
# prefilter and the group means); model$reduced, when present, makes DESeq()
# run a likelihood ratio test against that reduced formula.
# The shared pipeline in deseq2_analysis.R handles normalization, VST, and
# significant-gene selection identically for every design.

PLANNED_DESIGNS <- c("multi_condition")

# Metadata column names are user-supplied and may contain spaces or symbols, so
# the model uses safe internal names (covariate_1, ..., condition).
covariate_frame <- function(metadata, config, reserved) {
  coldata <- data.frame(row.names = rownames(metadata))
  for (index in seq_along(config$covariates)) {
    covariate <- config$covariates[[index]]
    if (covariate %in% reserved) {
      stop_input("The covariate '%s' cannot also be the sample, condition or time column.", covariate)
    }
    values <- require_column(metadata, covariate, "covariate")
    if (length(unique(values)) < 2) stop_input("The covariate '%s' has only one value, so it cannot be modeled.", covariate)
    coldata[[sprintf("covariate_%d", index)]] <- factor(values)
  }
  coldata
}

check_estimable <- function(formula, coldata, confounded_message) {
  design_matrix <- stats::model.matrix(formula, coldata)
  if (qr(design_matrix)$rank < ncol(design_matrix)) stop_input(confounded_message)
  if (nrow(design_matrix) <= ncol(design_matrix)) {
    stop_input("There are not enough samples to estimate the design (%d samples for %d coefficients).", nrow(design_matrix), ncol(design_matrix))
  }
}

model_frame <- function(metadata, config) {
  condition <- require_column(metadata, config$condition_column, "condition")
  coldata <- covariate_frame(metadata, config, c(config$sample_column, config$condition_column))

  coldata$condition <- stats::relevel(factor(condition), ref = config$reference_level)
  terms <- c(setdiff(colnames(coldata), "condition"), "condition")
  formula <- stats::as.formula(paste("~", paste(terms, collapse = " + ")))

  check_estimable(formula, coldata,
                  "The design cannot be estimated because the condition is confounded with a covariate (for example, every batch contains only one condition).")
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
  model$group <- model$coldata$condition
  model$contrast <- c("condition", test, reference)
  model$question <- sprintf("Which genes differ between %s and %s (the reference)?", test, reference)
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

# ---- Time-course designs -------------------------------------------------
# Time points are modeled as categories (one coefficient per time point), the
# approach of the DESeq2 vignette's time-course example. Numeric time values
# are ordered numerically and kept in the manifest so later stages (Gaussian
# process trajectories) can use the actual times.

ordered_times <- function(values, column) {
  times <- unique(values)
  numbers <- suppressWarnings(as.numeric(times))
  if (anyNA(numbers)) return(list(levels = times, numeric = NULL))

  same <- duplicated(numbers)
  if (any(same)) {
    stop_input("The time column '%s' writes the same time in different ways: %s. Please use one spelling per time point.",
               column, preview(times[numbers %in% numbers[same]]))
  }
  order <- order(numbers)
  list(levels = times[order], numeric = numbers[order])
}

# Saved in the manifest; numeric_values is null when the times are not numbers.
time_summary <- function(config, times) {
  list(column = config$time_column, levels = I(times$levels),
       numeric_values = if (is.null(times$numeric)) NULL else I(times$numeric),
       baseline = times$levels[[1]])
}

group_label <- function(condition, time) {
  if (is.null(condition)) paste("time", time) else paste0(condition, " @ time ", time)
}

check_replicates <- function(cells, config, description) {
  small <- cells[cells < config$min_replicates]
  if (length(small) > 0) {
    stop_input("Every %s needs at least %d biological replicates. Too few samples in: %s.",
               description, config$min_replicates,
               preview(sprintf("%s (%d)", names(small), as.integer(small)), 10))
  }
}

prepare_time_course <- function(metadata, config) {
  if (config$time_column == config$sample_column) stop_input("The time column must be different from the sample column.")
  require_column(metadata, config$time_column, "time")
  subset_description <- NULL
  if (!is.null(config$subset_level)) {
    if (config$condition_column %in% c(config$sample_column, config$time_column)) {
      stop_input("The condition column used to choose samples must be different from the sample and time columns.")
    }
    condition <- require_column(metadata, config$condition_column, "condition")
    if (!config$subset_level %in% condition) {
      stop_input("Condition level '%s' was not found in column '%s'. Available levels: %s.",
                 config$subset_level, config$condition_column, preview(sort(unique(condition)), 20))
    }
    metadata <- metadata[condition == config$subset_level, , drop = FALSE]
    subset_description <- sprintf("%s = %s", config$condition_column, config$subset_level)
  }

  times <- ordered_times(metadata[[config$time_column]], config$time_column)
  if (length(times$levels) < 2) stop_input("A time course needs at least two different time points in column '%s'.", config$time_column)
  cells <- table(factor(metadata[[config$time_column]], levels = times$levels))
  names(cells) <- group_label(NULL, names(cells))
  check_replicates(cells, config, "time point")

  coldata <- covariate_frame(metadata, config, c(config$sample_column, config$time_column,
                                                 if (!is.null(subset_description)) config$condition_column))
  coldata$time <- factor(metadata[[config$time_column]], levels = times$levels)
  covariates <- setdiff(colnames(coldata), "time")
  formula <- stats::as.formula(paste("~", paste(c(covariates, "time"), collapse = " + ")))
  reduced <- stats::as.formula(paste("~", if (length(covariates) > 0) paste(covariates, collapse = " + ") else "1"))
  check_estimable(formula, coldata,
                  "The design cannot be estimated because time is confounded with a covariate (for example, each batch contains only one time point).")

  list(
    coldata = coldata,
    formula = formula,
    reduced = reduced,
    description = sprintf("full: ~ %s; reduced: ~ %s (likelihood ratio test)",
                          paste(c(config$covariates, config$time_column), collapse = " + "),
                          if (length(config$covariates) > 0) paste(config$covariates, collapse = " + ") else "1"),
    question = paste0("Which genes change over time", if (!is.null(subset_description)) sprintf(" (samples with %s)", subset_description) else "", "?"),
    groups = as.list(stats::setNames(as.integer(cells), names(cells))),
    group = coldata$time,
    time = time_summary(config, times),
    subset = subset_description
  )
}

prepare_condition_by_time <- function(metadata, config) {
  if (config$time_column %in% c(config$sample_column, config$condition_column)) {
    stop_input("The time column must be different from the sample and condition columns.")
  }
  if (config$condition_column == config$sample_column) stop_input("The condition column must be different from the sample column.")
  reference <- config$reference_level
  test <- config$test_level
  if (reference == test) stop_input("The reference and test conditions must be different.")

  condition <- require_column(metadata, config$condition_column, "condition")
  require_column(metadata, config$time_column, "time")
  absent <- setdiff(c(reference, test), condition)
  if (length(absent) > 0) {
    stop_input("Condition levels not found in column '%s': %s. Available levels: %s.",
               config$condition_column, preview(absent), preview(sort(unique(condition)), 20))
  }
  # The interaction test compares exactly two conditions, so other levels are left out.
  metadata <- metadata[condition %in% c(reference, test), , drop = FALSE]

  times <- ordered_times(metadata[[config$time_column]], config$time_column)
  if (length(times$levels) < 2) stop_input("A time course needs at least two different time points in column '%s'.", config$time_column)
  cells <- table(factor(metadata[[config$condition_column]], levels = c(reference, test)),
                 factor(metadata[[config$time_column]], levels = times$levels))
  labels <- outer(rownames(cells), colnames(cells), group_label)
  counts <- stats::setNames(as.vector(cells), as.vector(labels))
  missing <- names(counts)[counts == 0]
  if (length(missing) > 0) {
    stop_input("Both conditions need samples at every time point to compare how they change over time. No samples for: %s.", preview(missing, 10))
  }
  check_replicates(counts, config, "condition and time point combination")

  coldata <- covariate_frame(metadata, config, c(config$sample_column, config$condition_column, config$time_column))
  coldata$condition <- factor(metadata[[config$condition_column]], levels = c(reference, test))
  coldata$time <- factor(metadata[[config$time_column]], levels = times$levels)
  covariates <- setdiff(colnames(coldata), c("condition", "time"))
  main_terms <- c(covariates, "condition", "time")
  formula <- stats::as.formula(paste("~", paste(c(main_terms, "condition:time"), collapse = " + ")))
  reduced <- stats::as.formula(paste("~", paste(main_terms, collapse = " + ")))
  check_estimable(formula, coldata,
                  "The design cannot be estimated because condition or time is confounded with a covariate.")

  user_terms <- c(config$covariates, config$condition_column, config$time_column)
  list(
    coldata = coldata,
    formula = formula,
    reduced = reduced,
    description = sprintf("full: ~ %s + %s:%s; reduced: ~ %s (likelihood ratio test)",
                          paste(user_terms, collapse = " + "), config$condition_column, config$time_column,
                          paste(user_terms, collapse = " + ")),
    question = sprintf("Which genes change differently over time in %s than in %s (the reference)?", test, reference),
    groups = as.list(counts[order(rep(seq_len(nrow(cells)), ncol(cells)))]),
    group = interaction(coldata$condition, coldata$time, drop = TRUE),
    contrast = c("condition", test, reference),
    time = time_summary(config, times)
  )
}

test_lrt <- function(dds, model, config) {
  if (config$lfc_threshold > 0 && config$lfc_test == "deseq2") {
    stop_input("A time-course analysis tests all time points at once, so the fold-change cutoff can only be applied after testing (lfc_test = 'posthoc').")
  }
  DESeq2::results(dds, alpha = config$alpha)
}

# Log2 fold changes between two kinds of sample, from the full model's
# coefficients: (x_a - x_b) %*% beta, where x is a design-matrix row. Covariate
# terms are identical in both rows and cancel.
design_row <- function(model, values) {
  row <- model$coldata[1, , drop = FALSE]
  for (name in names(values)) row[[name]] <- factor(values[[name]], levels = levels(model$coldata[[name]]))
  stats::model.matrix(model$formula, row)
}

coefficient_difference <- function(dds, model, a, b) {
  beta <- stats::coef(dds)
  difference <- design_row(model, a) - design_row(model, b)
  stopifnot(ncol(beta) == ncol(difference))
  as.vector(beta %*% t(difference))
}

effects_time_course <- function(dds, model) {
  baseline <- model$time$baseline
  later <- setdiff(model$time$levels, baseline)
  effects <- vapply(later, function(time) {
    coefficient_difference(dds, model, list(time = time), list(time = baseline))
  }, numeric(nrow(dds)))
  effects <- matrix(effects, nrow = nrow(dds))
  colnames(effects) <- sprintf("log2FC_time_%s_vs_%s", later, baseline)
  rownames(effects) <- rownames(dds)
  effects
}

effects_condition_by_time <- function(dds, model) {
  test <- model$contrast[[2]]
  reference <- model$contrast[[3]]
  times <- model$time$levels
  effects <- vapply(times, function(time) {
    coefficient_difference(dds, model, list(condition = test, time = time), list(condition = reference, time = time))
  }, numeric(nrow(dds)))
  effects <- matrix(effects, nrow = nrow(dds))
  colnames(effects) <- sprintf("log2FC_%s_vs_%s_at_time_%s", test, reference, times)
  rownames(effects) <- rownames(dds)
  effects
}

DESIGNS <- list(
  two_condition = list(prepare = prepare_two_condition, test = test_two_condition, effects = function(dds, model) NULL),
  time_course = list(prepare = prepare_time_course, test = test_lrt, effects = effects_time_course),
  condition_by_time = list(prepare = prepare_condition_by_time, test = test_lrt, effects = effects_condition_by_time)
)

design_for <- function(experiment_type) {
  if (experiment_type %in% names(DESIGNS)) return(DESIGNS[[experiment_type]])
  if (experiment_type %in% PLANNED_DESIGNS) {
    stop_input("The '%s' experiment type is not supported yet. Supported types: %s.",
               experiment_type, paste(names(DESIGNS), collapse = ", "))
  }
  stop_input("Unknown experiment type '%s'. Supported types: %s.", experiment_type, paste(names(DESIGNS), collapse = ", "))
}
