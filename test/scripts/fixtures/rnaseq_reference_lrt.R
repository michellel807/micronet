# Plain, textbook DESeq2 likelihood ratio tests used as an independent
# reference for the time-course designs in deseq2_analysis_test.py. It shares
# no code with lib/scripts/rnaseq, so wrapper bugs show up.
#
# Usage:
#   Rscript rnaseq_reference_lrt.R time_course counts.tsv metadata.tsv OUT_DIR SUBSET_LEVEL
#   Rscript rnaseq_reference_lrt.R condition_by_time counts.tsv metadata.tsv OUT_DIR REFERENCE TEST
# Times must be numbers; they are used as factor levels in numeric order.

suppressPackageStartupMessages(library(DESeq2))

args <- commandArgs(trailingOnly = TRUE)
type <- args[[1]]
out <- args[[4]]

counts <- as.matrix(read.delim(args[[2]], row.names = 1, check.names = FALSE))
storage.mode(counts) <- "integer"
metadata <- read.delim(args[[3]], check.names = FALSE, stringsAsFactors = FALSE)
rownames(metadata) <- metadata$sample
time_levels <- as.character(sort(unique(metadata$time)))

if (type == "time_course") {
  metadata <- metadata[metadata$condition == args[[5]], , drop = FALSE]
  metadata$time <- factor(as.character(metadata$time), levels = time_levels)
  counts <- counts[, rownames(metadata)]
  keep <- rowSums(counts >= 10) >= min(table(metadata$time))
  dds <- DESeqDataSetFromMatrix(counts[keep, ], metadata, design = ~ time)
  dds <- DESeq(dds, test = "LRT", reduced = ~ 1, quiet = TRUE)
  res <- results(dds, alpha = 0.05)
  effects <- sapply(time_levels[-1], function(time) {
    results(dds, name = paste0("time_", time, "_vs_", time_levels[[1]]), test = "Wald")$log2FoldChange
  })
  colnames(effects) <- sprintf("log2FC_time_%s_vs_%s", time_levels[-1], time_levels[[1]])
} else {
  reference <- args[[5]]
  test <- args[[6]]
  metadata <- metadata[metadata$condition %in% c(reference, test), , drop = FALSE]
  metadata$condition <- factor(metadata$condition, levels = c(reference, test))
  metadata$time <- factor(as.character(metadata$time), levels = time_levels)
  counts <- counts[, rownames(metadata)]
  keep <- rowSums(counts >= 10) >= min(table(metadata$condition, metadata$time))
  dds <- DESeqDataSetFromMatrix(counts[keep, ], metadata, design = ~ condition + time + condition:time)
  dds <- DESeq(dds, test = "LRT", reduced = ~ condition + time, quiet = TRUE)
  res <- results(dds, alpha = 0.05)
  beta <- coef(dds)
  main <- paste0("condition_", test, "_vs_", reference)
  effects <- sapply(time_levels, function(time) {
    if (time == time_levels[[1]]) beta[, main] else beta[, main] + beta[, paste0("condition", test, ".time", time)]
  })
  colnames(effects) <- sprintf("log2FC_%s_vs_%s_at_time_%s", test, reference, time_levels)
}

dir.create(out, recursive = TRUE, showWarnings = FALSE)
table <- data.frame(gene_id = rownames(res), baseMean = res$baseMean, stat = res$stat,
                    pvalue = res$pvalue, padj = res$padj, effects, check.names = FALSE)
write.table(table, file.path(out, "results.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
