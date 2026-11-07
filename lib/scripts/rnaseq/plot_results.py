"""Quality-control plots for a completed deseq2_analysis.R run.

Usage:
    python plot_results.py RESULTS_DIR

Reads manifest.json, deseq2_results.tsv, size_factors.tsv and vst_all.tsv from
RESULTS_DIR and writes pca.pdf, pca_coordinates.tsv, ma_plot.pdf and
volcano_plot.pdf beside them.
"""
import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

# DESeq2::plotPCA uses the 500 genes with the highest variance across samples.
PCA_TOP_GENES = 500
LABELED_GENES = 10
NOT_SIGNIFICANT = "#9a9a9a"
HIGHER = "#c0392b"
LOWER = "#2e6da4"
CONDITION_COLORS = ["#2e6da4", "#c0392b", "#27ae60", "#8e44ad", "#d68910", "#17a589"]
OUTPUTS = {"pca": "pca.pdf", "pca_coordinates": "pca_coordinates.tsv",
           "ma": "ma_plot.pdf", "volcano": "volcano_plot.pdf"}


def read_table(path):
    frame = pd.read_csv(path, sep="\t", keep_default_na=False, na_values=["NA"])
    return frame.set_index(frame.columns[0])


def principal_components(vst, top=PCA_TOP_GENES):
    """Return (samples x [PC1, PC2] coordinates, fraction of variance each explains)."""
    variable = vst.var(axis=1, ddof=1).sort_values(ascending=False, kind="stable").index[:top]
    centred = vst.loc[variable].T
    centred = centred - centred.mean(axis=0)
    u, s, _ = np.linalg.svd(centred.to_numpy(), full_matrices=False)
    explained = s ** 2 / np.sum(s ** 2)
    coordinates = np.zeros((len(centred), 2))
    components = min(2, len(s))
    coordinates[:, :components] = (u * s)[:, :components]
    explained = np.pad(explained[:components], (0, 2 - components))
    return pd.DataFrame(coordinates, index=centred.index, columns=["PC1", "PC2"]), explained


def plot_pca(vst, conditions, directory):
    coordinates, explained = principal_components(vst)
    coordinates.insert(0, "condition", conditions.loc[coordinates.index])
    coordinates.index.name = "sample"
    coordinates.to_csv(directory / OUTPUTS["pca_coordinates"], sep="\t")

    figure, axes = plt.subplots(figsize=(6.5, 5))
    for color, (condition, group) in zip(CONDITION_COLORS * 10, coordinates.groupby("condition", sort=False)):
        axes.scatter(group["PC1"], group["PC2"], s=60, color=color, label=condition, edgecolor="white", linewidth=0.8)
        for sample, row in group.iterrows():
            axes.annotate(sample, (row["PC1"], row["PC2"]), fontsize=7, xytext=(4, 4), textcoords="offset points")
    axes.set_xlabel(f"PC1: {explained[0]:.0%} of variance")
    axes.set_ylabel(f"PC2: {explained[1]:.0%} of variance")
    top = min(PCA_TOP_GENES, len(vst))
    axes.set_title(f"Sample PCA (VST, {top} most variable genes)", fontsize=10)
    axes.legend(title=conditions.name, fontsize=8)
    save(figure, directory / OUTPUTS["pca"])


def plot_ma(results, contrast, directory):
    shown = results[(results["baseMean"] > 0) & results["log2FoldChange"].notna()]
    significant = shown["significant"]
    figure, axes = plt.subplots(figsize=(6.5, 5))
    axes.scatter(shown.loc[~significant, "baseMean"], shown.loc[~significant, "log2FoldChange"],
                 s=5, color=NOT_SIGNIFICANT, alpha=0.5, linewidth=0, label="Not significant")
    axes.scatter(shown.loc[significant, "baseMean"], shown.loc[significant, "log2FoldChange"],
                 s=7, color=HIGHER, alpha=0.8, linewidth=0, label=f"Significant ({int(significant.sum())})")
    axes.axhline(0, color="black", linewidth=0.8)
    axes.set_xscale("log")
    axes.set_xlabel("Mean of normalized counts")
    axes.set_ylabel(contrast)
    axes.set_title("MA plot", fontsize=10)
    axes.legend(fontsize=8)
    save(figure, directory / OUTPUTS["ma"])


def plot_volcano(results, contrast, test_level, directory):
    shown = results[results["pvalue"].notna() & results["log2FoldChange"].notna()].copy()
    # p-values below the smallest double print as 0; plot them at that floor.
    shown["neg_log10_p"] = -np.log10(shown["pvalue"].clip(lower=np.finfo(float).tiny))
    significant = shown["significant"]
    higher = significant & (shown["log2FoldChange"] > 0)
    lower = significant & (shown["log2FoldChange"] < 0)

    figure, axes = plt.subplots(figsize=(6.5, 5))
    for mask, color, alpha, label in [(~significant, NOT_SIGNIFICANT, 0.4, "Not significant"),
                                      (higher, HIGHER, 0.8, f"Higher in {test_level} ({int(higher.sum())})"),
                                      (lower, LOWER, 0.8, f"Lower in {test_level} ({int(lower.sum())})")]:
        axes.scatter(shown.loc[mask, "log2FoldChange"], shown.loc[mask, "neg_log10_p"],
                     s=6, color=color, alpha=alpha, linewidth=0, label=label)
    for gene, row in shown[significant].nsmallest(LABELED_GENES, "padj").iterrows():
        axes.annotate(gene, (row["log2FoldChange"], row["neg_log10_p"]), fontsize=6, xytext=(3, 3), textcoords="offset points")
    axes.axvline(0, color="black", linewidth=0.8)
    axes.set_xlabel(contrast)
    axes.set_ylabel("-log10 p-value")
    axes.set_title("Volcano plot (colored: significant after multiple-testing adjustment)", fontsize=10)
    axes.legend(fontsize=8)
    save(figure, directory / OUTPUTS["volcano"])


def save(figure, path):
    figure.tight_layout()
    figure.savefig(path)
    plt.close(figure)


def main(results_dir):
    directory = Path(results_dir)
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("status") != "completed":
        raise SystemExit("The differential expression results are incomplete; no plots were drawn.")
    contrast = f"log2 fold change, {manifest['contrast']['log2_fold_change']}"

    results = read_table(directory / manifest["outputs"]["results"])
    results["significant"] = results["significant"].astype(str).str.upper().eq("TRUE")
    vst = read_table(directory / manifest["outputs"]["vst_all"])
    samples = read_table(directory / manifest["outputs"]["size_factors"])
    conditions = samples["condition"].rename(manifest["contrast"]["variable"])

    plot_pca(vst, conditions, directory)
    plot_ma(results, contrast, directory)
    plot_volcano(results, contrast, manifest["contrast"]["test_level"], directory)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
