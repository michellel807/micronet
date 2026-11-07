# File reading/writing and argument parsing shared by the RNA-seq R scripts.

# Errors caused by the user's files or settings. The entry script reports these
# as "input_error" so the web app can show the message instead of a crash.
input_error <- function(message) {
  structure(
    class = c("micronet_input_error", "error", "condition"),
    list(message = message, call = NULL)
  )
}

stop_input <- function(format, ...) {
  stop(input_error(sprintf(format, ...)))
}

# "a, b, c, d, e, and 3 more" keeps error messages short for large datasets.
preview <- function(values, limit = 5) {
  values <- as.character(values)
  shown <- utils::head(values, limit)
  if (length(values) > limit) {
    shown <- c(shown, sprintf("and %d more", length(values) - limit))
  }
  paste(shown, collapse = ", ")
}

parse_args <- function(args, required) {
  values <- list()
  index <- 1
  while (index <= length(args)) {
    key <- args[[index]]
    if (!startsWith(key, "--") || index == length(args)) {
      stop(sprintf("Invalid argument: %s", key))
    }
    values[[substring(key, 3)]] <- args[[index + 1]]
    index <- index + 2
  }
  missing <- setdiff(required, names(values))
  if (length(missing) > 0) {
    stop(sprintf("Missing required arguments: %s", paste0("--", missing, collapse = ", ")))
  }
  values
}

# Reads every cell as text so validation can report exactly which value is bad.
# CSV is detected by extension; everything else is treated as tab-delimited,
# matching how MicroNet's upload models normalize files.
read_delimited <- function(path, label, keep_row_names = FALSE) {
  if (!file.exists(path)) stop_input("The %s file was not found.", label)

  separator <- if (tolower(tools::file_ext(path)) == "csv") "," else "\t"
  table <- tryCatch(
    utils::read.table(
      path, sep = separator, header = TRUE, quote = "\"", comment.char = "",
      colClasses = "character", check.names = FALSE, na.strings = character(0),
      fileEncoding = "UTF-8-BOM", strip.white = TRUE, blank.lines.skip = TRUE
    ),
    error = function(e) stop_input("The %s file could not be read: %s", label, conditionMessage(e))
  )
  if (nrow(table) == 0) stop_input("The %s file has no data rows.", label)

  # Matrices exported from R (write.csv) have one fewer header field, so
  # read.table turns the gene IDs into row names. Move them back into a column.
  if (keep_row_names && .row_names_info(table) > 0) {
    table <- data.frame(gene_id = rownames(table), table, check.names = FALSE, stringsAsFactors = FALSE)
    rownames(table) <- NULL
  }
  table
}

read_config <- function(path) {
  if (!file.exists(path)) stop_input("The analysis configuration file was not found.")
  tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) stop_input("The analysis configuration is not valid JSON: %s", conditionMessage(e))
  )
}

write_tsv <- function(data, path) {
  utils::write.table(data, path, sep = "\t", quote = FALSE, row.names = FALSE, na = "NA")
}

# Genes × samples matrix as a table whose first column is gene_id.
matrix_table <- function(values) {
  data.frame(
    gene_id = rownames(values), values,
    check.names = FALSE, stringsAsFactors = FALSE, row.names = NULL
  )
}

write_json <- function(data, path) {
  jsonlite::write_json(data, path, auto_unbox = TRUE, pretty = TRUE, digits = NA, null = "null", na = "null")
}
