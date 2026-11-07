# Plain, textbook DESeq2 used as an independent reference by deseq2_analysis_test.py.
# It deliberately shares no code with lib/scripts/rnaseq so wrapper bugs show up.
#
# Usage: Rscript rnaseq_reference_deseq2.R counts.tsv metadata.tsv REFERENCE TEST OUT_DIR [GENES_FILE]
#
# With GENES_FILE, also writes vst_subset_first.tsv: the VST computed after
# subsetting to those genes, i.e. the wrong order. Tests use it to show that
# the order of selection and transformation changes the result.

suppressPackageStartupMessages(library(DESeq2))

args <- commandArgs(trailingOnly = TRUE)
reference <- args[[3]]
test <- args[[4]]
out <- args[[5]]

counts <- as.matrix(read.delim(args[[1]], row.names = 1, check.names = FALSE))
storage.mode(counts) <- "integer"
metadata <- read.delim(args[[2]], check.names = FALSE, stringsAsFactors = FALSE)
rownames(metadata) <- metadata$sample
metadata <- metadata[colnames(counts), , drop = FALSE]
metadata$condition <- relevel(factor(metadata$condition), ref = reference)

keep <- rowSums(counts >= 10) >= min(table(metadata$condition))
dds <- DESeqDataSetFromMatrix(counts[keep, ], metadata, design = ~ condition)
dds <- DESeq(dds, quiet = TRUE)
res <- results(dds, contrast = c("condition", test, reference), alpha = 0.05)

transform <- function(object) {
  if (sum(rowMeans(counts(object, normalized = TRUE)) > 5) >= 1000) {
    vst(object, blind = FALSE)
  } else {
    varianceStabilizingTransformation(object, blind = FALSE)
  }
}

write_matrix <- function(values, name) {
  write.table(data.frame(gene_id = rownames(values), values, check.names = FALSE),
              file.path(out, name), sep = "\t", quote = FALSE, row.names = FALSE)
}

dir.create(out, recursive = TRUE, showWarnings = FALSE)
write.table(data.frame(gene_id = rownames(res), as.data.frame(res)),
            file.path(out, "results.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
write.table(data.frame(sample = colnames(dds), size_factor = sizeFactors(dds)),
            file.path(out, "size_factors.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
write_matrix(assay(transform(dds)), "vst_all.tsv")

if (length(args) >= 6) {
  genes <- readLines(args[[6]])
  subset_first <- DESeqDataSetFromMatrix(counts[genes, ], metadata, design = ~ condition)
  subset_first <- DESeq(subset_first, quiet = TRUE)
  write_matrix(assay(transform(subset_first)), "vst_subset_first.tsv")
}
