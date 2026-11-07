"""Package a completed RNA-seq results directory for delivery.

Usage:
    python package_results.py RESULTS_DIR ZIP_PATH --job-number N

Writes significant_genes.tsv and README.txt into RESULTS_DIR, then zips every
file in RESULTS_DIR into ZIP_PATH under the folder rnaseq_results_job<N>/.
"""
import argparse
import csv
import json
import zipfile
from datetime import datetime, timezone
from pathlib import Path

SIGNIFICANT_GENES = "significant_genes.tsv"
README = "README.txt"
DESCRIPTIONS = {
    README: "This file.",
    "manifest.json": "Machine-readable summary: settings, gene counts at each step, software versions, warnings.",
    "deseq2_results.tsv": "Every tested gene: baseMean, log2FoldChange, lfcSE, stat, pvalue, padj, significant, and why padj is missing (padj_na_reason).",
    SIGNIFICANT_GENES: "The significant rows of deseq2_results.tsv.",
    "size_factors.tsv": "DESeq2 median-of-ratios size factor for each sample.",
    "normalized_counts.tsv": "Raw counts divided by each sample's size factor.",
    "vst_all.tsv": "Variance-stabilized expression (log2-like scale) for every gene that passed the low-count filter.",
    "vst_significant.tsv": "The significant genes' rows of vst_all.tsv. Use these values for heatmaps and clustering.",
    "pca.pdf": "Principal component plot of samples, from the 500 most variable genes of vst_all.tsv.",
    "pca_coordinates.tsv": "The sample coordinates plotted in pca.pdf.",
    "ma_plot.pdf": "Fold change against mean expression; significant genes colored.",
    "volcano_plot.pdf": "Fold change against -log10 p-value; significant genes colored.",
}
NA_REASONS = {
    "cooks_outlier": "a sample had an extreme count (Cook's distance), so no p-value was computed",
    "independent_filtering": "the gene's mean count was too low to be tested usefully (independent filtering)",
}


def write_significant_genes(directory, results_name):
    """Copy the significant rows verbatim, so numbers match deseq2_results.tsv exactly."""
    with open(directory / results_name, newline="") as source, \
            open(directory / SIGNIFICANT_GENES, "w", newline="") as target:
        reader = csv.reader(source, delimiter="\t")
        writer = csv.writer(target, delimiter="\t", lineterminator="\n")
        header = next(reader)
        column = header.index("significant")
        writer.writerow(header)
        for row in reader:
            if row[column].upper() == "TRUE":
                writer.writerow(row)


def readme(manifest, job_number, files):
    contrast, parameters, genes, samples = (manifest["contrast"], manifest["parameters"],
                                            manifest["genes"], manifest["samples"])
    test, reference = contrast["test_level"], contrast["reference_level"]
    significance = f"adjusted p-value (padj) < {parameters['alpha']}"
    if parameters["lfc_threshold"] > 0:
        how = ("tested by DESeq2 (lfcThreshold)" if parameters["lfc_test"] == "deseq2"
               else "applied after testing")
        significance += f" and |log2 fold change| >= {parameters['lfc_threshold']}, {how}"
    groups = ", ".join(f"{level}: {count}" for level, count in samples["per_group"].items())
    excluded = samples["in_input"] - samples["in_model"]

    lines = [
        f"MicroNet RNA-seq results, Job #{job_number}",
        f"Created {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC",
        "",
        "ANALYSIS",
        f"  Method: DESeq2 differential expression ({manifest['experiment_type'].replace('_', '-')})",
        f"  Design formula: {manifest['design']}",
        f"  Comparison: {contrast['log2_fold_change']}.",
        f"    A positive log2 fold change means higher expression in {test} than in {reference}.",
        f"  Samples in the model: {samples['in_model']} ({groups})"
        + (f"; {excluded} other samples were excluded" if excluded else ""),
        f"  Significant genes: {significance}",
        "",
        "GENES",
        f"  In the count matrix: {genes['in_input']}",
        f"  Passed the low-count filter (>= {parameters['prefilter']['min_count']} counts in at least "
        f"{genes['prefilter_min_samples']} samples): {genes['passed_prefilter']}",
        f"  Tested: {genes['tested']}",
    ]
    for reason, count in genes["padj_na"].items():
        if count:
            lines.append(f"  No adjusted p-value for {count} genes: {NA_REASONS.get(reason, reason)}")
    lines += [
        f"  Significant: {genes['significant']} ({genes['significant_up']} higher and "
        f"{genes['significant_down']} lower in {test})",
        "",
        "HOW THE RESULTS WERE COMPUTED",
        "  1. Genes with too few counts were removed.",
        "  2. DESeq2 estimated size factors and dispersions from all remaining genes and",
        "     tested each gene on the raw counts.",
        f"  3. The variance-stabilizing transformation ({manifest['vst_method']}, blind = "
        f"{str(parameters['vst_blind']).upper()}) was applied to all remaining genes.",
        "  4. Only then were significant genes selected, so vst_significant.tsv holds values",
        "     transformed together with the whole dataset.",
        "",
        "FILES",
    ]
    lines += [f"  {name}\n      {DESCRIPTIONS.get(name, '')}".rstrip() for name in files]
    if manifest.get("warnings"):
        lines += ["", "WARNINGS FROM THE ANALYSIS"] + [f"  - {warning}" for warning in manifest["warnings"]]
    versions = manifest["versions"]
    lines += [
        "",
        "SOFTWARE",
        f"  {versions['R']}; DESeq2 {versions['DESeq2']}",
        "",
        "CITATION",
        "  Love MI, Huber W, Anders S (2014). Moderated estimation of fold change and",
        "  dispersion for RNA-seq data with DESeq2. Genome Biology 15:550.",
        "",
    ]
    return "\n".join(lines)


def main(results_dir, zip_path, job_number):
    directory = Path(results_dir)
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("status") != "completed":
        raise SystemExit("The differential expression results are incomplete; nothing was packaged.")

    write_significant_genes(directory, manifest["outputs"]["results"])
    files = sorted({path.name for path in directory.iterdir() if path.is_file()} | {README},
                   key=lambda name: (list(DESCRIPTIONS).index(name) if name in DESCRIPTIONS else len(DESCRIPTIONS), name))
    (directory / README).write_text(readme(manifest, job_number, files))

    folder = f"rnaseq_results_job{job_number}"
    zip_path = Path(zip_path)
    partial = zip_path.with_name(zip_path.name + ".partial")
    with zipfile.ZipFile(partial, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            archive.write(directory / name, f"{folder}/{name}")
    partial.replace(zip_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_dir")
    parser.add_argument("zip_path")
    parser.add_argument("--job-number", required=True)
    arguments = parser.parse_args()
    main(arguments.results_dir, arguments.zip_path, arguments.job_number)
