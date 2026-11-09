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
    "group_means_vst.tsv": "Mean VST value of every gene in each group (condition and time point), one row per gene and group, "
                           "with the numeric time (time_value) when the times are numbers. Use these for trajectory plots and modeling.",
    "top_gene_trajectories.pdf": "The most significant genes over time: group means as lines, each sample as a dot.",
    "gene_clusters.tsv": "The cluster of each clustered gene, with its padj, largest fold change, and distance from its cluster's "
                         "average pattern (small = typical member). Sorted by cluster, most typical genes first.",
    "cluster_profiles.tsv": "Each cluster's average pattern: mean and standard deviation of the genes' z-scores in every group "
                            "(condition and time point), with the numeric time (time_value).",
    "cluster_selection.tsv": "The silhouette score and within-cluster spread for each number of clusters tried; chosen marks the one used.",
    "cluster_trajectories.pdf": "One panel per cluster: each gene's z-scored pattern over time as a thin line, the cluster average in bold.",
    "cluster_selection.pdf": "Silhouette score against the number of clusters, with the number used circled.",
}
TIME_COURSE_RESULTS = ("Every tested gene: baseMean, the likelihood ratio test statistic (stat), pvalue, padj, significant, "
                       "why padj is missing (padj_na_reason), and log2 fold changes at each time point (log2FC_* columns; "
                       "max_abs_log2FC is the largest of them in absolute value).")
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


def comparison_lines(manifest):
    """How to read the test and the fold changes, for each experiment type."""
    contrast, time = manifest.get("contrast"), manifest.get("time")
    if not time:
        test, reference = contrast["test_level"], contrast["reference_level"]
        return [f"  Comparison: {contrast['log2_fold_change']}.",
                f"    A positive log2 fold change means higher expression in {test} than in {reference}."]

    levels = ", ".join(str(level) for level in time["levels"])
    lines = [f"  Question: {manifest.get('question', '')}",
             f"  Time points ({time['column']}), treated as categories: {levels}"]
    if manifest["experiment_type"] == "condition_by_time":
        test, reference = contrast["test_level"], contrast["reference_level"]
        lines += [
            "  Test: likelihood ratio test of the condition-by-time interaction. A significant gene's",
            f"    difference between {test} and {reference} changes over time; genes that differ by the same",
            "    amount at every time point are not called.",
            f"  log2FC_{test}_vs_{reference}_at_time_T: log2({test} / {reference}) at time T.",
        ]
    else:
        lines += [
            "  Test: likelihood ratio test of time. A significant gene changes at one or more time points.",
            f"  log2FC_time_T_vs_{time['baseline']}: log2(expression at time T / expression at time {time['baseline']}).",
        ]
    return lines


def silhouette_meaning(score):
    if score >= 0.5:
        return "the clusters are clearly separated"
    if score >= 0.25:
        return "the clusters are reasonably separated, with some genes between patterns"
    return ("the patterns blend into each other, so treat the clusters as a convenient split "
            "rather than distinct groups")


def clustering_lines(clustering):
    """The CLUSTERS section of the README, or nothing when clustering did not run."""
    if not clustering:
        return []
    lines = ["", "CLUSTERS"]
    if clustering.get("status") != "completed":
        return lines + [f"  Not clustered: {clustering.get('reason', 'clustering did not run')}"]
    if clustering["chosen_by"] == "user":
        how = f"You chose {clustering['clusters']} clusters."
    else:
        how = (f"{clustering['clusters']} clusters: of the numbers tried (2 to 10), this one gave the highest\n"
               "  silhouette score (see cluster_selection.pdf).")
    sizes = ", ".join(f"{number}: {size}" for number, size in enumerate(clustering["cluster_sizes"], start=1))
    lines += [
        "  The significant genes were grouped by the shape of their change over time.",
        "  1. Each gene's mean expression (vst) in every group (condition and time point) was",
        "     converted to z-scores (its own mean subtracted, divided by its own standard deviation),",
        "     so genes with the same pattern group together however highly they are expressed.",
        "  2. k-means clustering (k-means++ starts, 10 restarts, fixed seed, so reruns give the",
        "     same clusters) grouped the patterns. Clusters are numbered by size, largest first.",
        f"  {how}",
        f"  Genes clustered: {clustering['genes_clustered']}"
        + (f" ({clustering['genes_excluded']} significant genes without a usable pattern were left out)"
           if clustering.get("genes_excluded") else ""),
        f"  Cluster sizes: {sizes}",
        f"  Silhouette score: {clustering['silhouette']:.2f} (from -1 to 1; {silhouette_meaning(clustering['silhouette'])}).",
    ]
    if clustering.get("silhouette_sampled_genes"):
        lines.append(f"    The score was computed on a fixed random sample of {clustering['silhouette_sampled_genes']} genes.")
    return lines


def readme(manifest, job_number, files):
    parameters, genes, samples = manifest["parameters"], manifest["genes"], manifest["samples"]
    time_course = bool(manifest.get("time"))
    significance = f"adjusted p-value (padj) < {parameters['alpha']}"
    if parameters["lfc_threshold"] > 0:
        how = ("tested by DESeq2 (lfcThreshold)" if parameters["lfc_test"] == "deseq2"
               else "applied after testing")
        size = "largest |log2 fold change| across time points" if time_course else "|log2 fold change|"
        significance += f" and {size} >= {parameters['lfc_threshold']}, {how}"
    groups = ", ".join(f"{level}: {count}" for level, count in samples["per_group"].items())
    excluded = samples["in_input"] - samples["in_model"]

    lines = [
        f"MicroNet RNA-seq results, Job #{job_number}",
        f"Created {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC",
        "",
        "ANALYSIS",
        f"  Method: DESeq2 differential expression ({manifest['experiment_type'].replace('_', '-')})",
        f"  Design formula: {manifest['design']}",
        *comparison_lines(manifest),
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
    if genes.get("significant_up") is not None:
        lines.append(f"  Significant: {genes['significant']} ({genes['significant_up']} higher and "
                     f"{genes['significant_down']} lower in {manifest['contrast']['test_level']})")
    else:
        lines.append(f"  Significant: {genes['significant']}")
    lines += [
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
    ]
    lines += clustering_lines(manifest.get("clustering"))
    lines += [
        "",
        "FILES",
    ]
    descriptions = {**DESCRIPTIONS, **({"deseq2_results.tsv": TIME_COURSE_RESULTS} if time_course else {})}
    lines += [f"  {name}\n      {descriptions.get(name, '')}".rstrip() for name in files]
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
