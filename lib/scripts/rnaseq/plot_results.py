"""Quality-control plots for a completed deseq2_analysis.R run.

Usage:
    python plot_results.py RESULTS_DIR

Reads manifest.json, deseq2_results.tsv, size_factors.tsv and vst_all.tsv from
RESULTS_DIR and writes pca.pdf and pca_coordinates.tsv beside them, plus
ma_plot.pdf and volcano_plot.pdf for a two-condition comparison, or
top_gene_trajectories.pdf (from group_means_vst.tsv) for a time course. When
cluster_genes.py has clustered a time course, also cluster_trajectories.pdf and
cluster_selection.pdf, and when gp_trajectories.py has fitted curves,
cluster_gp_curves.pdf (plus cluster_gp_differences.pdf comparing conditions),
one page per cluster drawn with the growth Gaussian Process Plot's helpers
(lib/scripts/otherscripts/gpplot.py) so both look the same.
"""
import importlib.util
import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from matplotlib.backends.backend_pdf import PdfPages  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "gpplot", Path(__file__).resolve().parents[1] / "otherscripts" / "gpplot.py")
gpplot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gpplot)

# DESeq2::plotPCA uses the 500 genes with the highest variance across samples.
PCA_TOP_GENES = 500
LABELED_GENES = 10
NOT_SIGNIFICANT = "#9a9a9a"
HIGHER = "#c0392b"
LOWER = "#2e6da4"
CONDITION_COLORS = ["#2e6da4", "#c0392b", "#27ae60", "#8e44ad", "#d68910", "#17a589"]
TIME_COLORS = "viridis"
MARKERS = ["o", "s", "^", "D", "v", "P"]
TRAJECTORY_GENES = 12
OUTPUTS = {"pca": "pca.pdf", "pca_coordinates": "pca_coordinates.tsv",
           "ma": "ma_plot.pdf", "volcano": "volcano_plot.pdf",
           "trajectories": "top_gene_trajectories.pdf",
           "cluster_trajectories": "cluster_trajectories.pdf", "cluster_selection": "cluster_selection.pdf",
           "gp_curves": "cluster_gp_curves.pdf", "gp_differences": "cluster_gp_differences.pdf"}


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


def plot_time_pca(vst, samples, time_levels, condition_name, directory):
    """PCA colored by time point (in time order), one marker shape per condition."""
    coordinates, explained = principal_components(vst)
    info = samples.loc[coordinates.index]
    has_condition = "condition" in info.columns
    if has_condition:
        coordinates.insert(0, "condition", info["condition"])
    coordinates.insert(1 if has_condition else 0, "time", info["time"].astype(str))
    coordinates.index.name = "sample"
    coordinates.to_csv(directory / OUTPUTS["pca_coordinates"], sep="\t")

    colors = plt.get_cmap(TIME_COLORS)(np.linspace(0.05, 0.9, len(time_levels)))
    color_of = dict(zip(time_levels, colors))
    conditions = list(dict.fromkeys(coordinates["condition"])) if has_condition else [None]
    figure, axes = plt.subplots(figsize=(6.5, 5))
    for marker, condition in zip(MARKERS * 10, conditions):
        group = coordinates if condition is None else coordinates[coordinates["condition"] == condition]
        axes.scatter(group["PC1"], group["PC2"], s=60, c=[color_of[time] for time in group["time"]],
                     marker=marker, edgecolor="white", linewidth=0.8)
    for time in time_levels:
        axes.scatter([], [], s=50, color=color_of[time], label=f"time {time}")
    if has_condition:
        for marker, condition in zip(MARKERS * 10, conditions):
            axes.scatter([], [], s=50, color="#555555", marker=marker, label=f"{condition_name} {condition}")
    axes.set_xlabel(f"PC1: {explained[0]:.0%} of variance")
    axes.set_ylabel(f"PC2: {explained[1]:.0%} of variance")
    top = min(PCA_TOP_GENES, len(vst))
    axes.set_title(f"Sample PCA (VST, {top} most variable genes)", fontsize=10)
    axes.legend(fontsize=7)
    save(figure, directory / OUTPUTS["pca"])


def time_positions(time_info):
    """Time levels and their x positions: the real times when they are numbers, otherwise evenly spaced."""
    levels = [str(level) for level in time_info["levels"]]
    numeric = time_info.get("numeric_values")
    return levels, dict(zip(levels, numeric if numeric else range(len(levels))))


def plot_clusters(clusters, profiles, means, manifest, directory):
    """Each cluster's genes over time (z-scores), with the cluster mean in bold."""
    levels, position = time_positions(manifest["time"])
    clustering = manifest["clustering"]
    means = means.assign(time=means["time"].astype(str), condition=means["condition"].fillna("").astype(str))
    profiles = profiles.assign(time=profiles["time"].astype(str), condition=profiles["condition"].fillna("").astype(str))
    groups = [(group["condition"], str(group["time"])) for group in clustering["groups"]]
    matrix = (means[means["gene_id"].isin(set(clusters["gene_id"]))]
              .pivot_table(index="gene_id", columns=["condition", "time"], values="mean_vst", aggfunc="first")
              .reindex(columns=pd.MultiIndex.from_tuples(groups)))
    values = matrix.to_numpy(dtype=float)
    scaled = pd.DataFrame((values - values.mean(axis=1, keepdims=True)) / values.std(axis=1, keepdims=True),
                          index=matrix.index, columns=matrix.columns)
    conditions = list(dict.fromkeys(condition for condition, _ in groups))
    count = clustering["clusters"]
    columns = min(4, count)
    rows = int(np.ceil(count / columns))
    figure, grid = plt.subplots(rows, columns, figsize=(2.9 * columns + 0.6, 2.5 * rows + 0.9), squeeze=False,
                                sharex=True, sharey=True)
    for number, axes in zip(range(1, count + 1), grid.flat):
        members = clusters.loc[clusters["cluster"] == number, "gene_id"]
        for color, condition in zip(CONDITION_COLORS * 10, conditions):
            times = [time for (group_condition, time) in groups if group_condition == condition]
            x = [position[time] for time in times]
            lines = scaled.loc[members, [(condition, time) for time in times]].to_numpy()
            axes.plot(x, lines.T, color=color, alpha=min(0.5, 8 / max(len(lines), 1)), linewidth=0.6)
            mean = profiles[(profiles["cluster"] == number) & (profiles["condition"] == condition)].set_index("time")
            axes.plot(x, mean.loc[times, "mean_z"], color=color, linewidth=2.5, marker="o", markersize=4,
                      label=condition or None)
        axes.axhline(0, color=NOT_SIGNIFICANT, linewidth=0.5, zorder=0)
        axes.set_title(f"Cluster {number}: {len(members)} genes", fontsize=9)
        axes.set_xticks([position[time] for time in levels])
        axes.set_xticklabels(levels, fontsize=7)
        axes.tick_params(axis="y", labelsize=7)
    for axes in list(grid.flat)[count:]:
        axes.axis("off")
    if conditions != [""]:
        grid.flat[0].legend(fontsize=7)
    figure.supxlabel(f"Time ({manifest['time']['column']})", fontsize=9)
    figure.supylabel("Expression, z-score within each gene", fontsize=9)
    how = "number set by you" if clustering["chosen_by"] == "user" else "number chosen by silhouette score"
    figure.suptitle(f"Gene clusters by pattern over time ({how}; thin lines: genes, bold: cluster mean)", fontsize=10)
    save(figure, directory / OUTPUTS["cluster_trajectories"])


def plot_cluster_selection(selection, manifest, directory):
    """Silhouette score for each number of clusters tried, with the one used marked."""
    figure, axes = plt.subplots(figsize=(5.5, 3.8))
    axes.plot(selection["k"], selection["silhouette"], color=LOWER, marker="o")
    chosen = selection[selection["chosen"].astype(str).str.upper().eq("TRUE")]
    axes.scatter(chosen["k"], chosen["silhouette"], s=120, facecolors="none", edgecolors=HIGHER, linewidths=2,
                 label=f"Used: {int(chosen['k'].iloc[0])} clusters", zorder=3)
    axes.set_xticks(selection["k"])
    axes.set_xlabel("Number of clusters")
    axes.set_ylabel("Mean silhouette (higher = better separated)")
    axes.set_title("Choosing the number of gene clusters", fontsize=10)
    axes.legend(fontsize=8)
    save(figure, directory / OUTPUTS["cluster_selection"])


def gp_pages(path, numbers, draw):
    """One growth-style Gaussian Process Plot page per cluster in a multi-page PDF."""
    with plt.rc_context(gpplot.STYLE), PdfPages(path) as pdf:
        for number in numbers:
            figure, axes = plt.subplots(figsize=gpplot.FIGURE_SIZE)
            draw(axes, number)
            figure.tight_layout()
            pdf.savefig(figure)
            plt.close(figure)


def gp_time_axis(axes, manifest):
    levels, position = time_positions(manifest["time"])
    axes.set_xticks([position[time] for time in levels])
    axes.set_xticklabels(levels)
    return f"Time ({manifest['time']['column']})"


def plot_gp_curves(curves, points, manifest, directory):
    """Each cluster's GP mean curve and 95% band per condition, with each sample as a faint dot."""
    gp = manifest["gaussian_process"]
    curves = curves.assign(condition=curves["condition"].fillna("").astype(str))
    points = points.assign(condition=points["condition"].fillna("").astype(str))
    sizes = manifest["clustering"]["cluster_sizes"]

    def draw(axes, number):
        for condition in gp["conditions"]:
            curve = curves[(curves["cluster"] == number) & (curves["condition"] == condition)]
            line = gpplot.draw_gp_curve(axes, curve["time"], curve["mean"], curve["sd"], condition or f"Cluster {number}")
            dots = points[(points["cluster"] == number) & (points["condition"] == condition)]
            axes.scatter(dots["time"], dots["mean_z"], color=line.get_color(), s=12, alpha=0.35, linewidth=0)
        xlabel = gp_time_axis(axes, manifest)
        gpplot.finish_gp_plot(axes, f"Gaussian Process Plot: Cluster {number} ({sizes[number - 1]} genes)",
                              "Cluster mean expression (z-score)", xlabel)

    gp_pages(directory / OUTPUTS["gp_curves"], range(1, manifest["clustering"]["clusters"] + 1), draw)


def plot_gp_differences(differences, manifest, directory):
    """Test minus reference curve per cluster; lightly shaded where the 95% band excludes 0."""
    difference = manifest["gaussian_process"]["difference"]
    label = f"{difference['test_level']} minus {difference['reference_level']}"

    def draw(axes, number):
        curve = differences[differences["cluster"] == number]
        axes.axhline(0, color="black", linewidth=0.8)
        gpplot.draw_gp_curve(axes, curve["time"], curve["difference"], curve["sd"], label)
        for interval in difference["intervals"].get(str(number), []):
            axes.axvspan(interval["start"], interval["end"], color=HIGHER, alpha=0.08, linewidth=0)
        xlabel = gp_time_axis(axes, manifest)
        gpplot.finish_gp_plot(axes, f"Gaussian Process Difference: Cluster {number}", f"{label} (z-score)", xlabel)

    gp_pages(directory / OUTPUTS["gp_differences"], range(1, manifest["clustering"]["clusters"] + 1), draw)


def plot_trajectories(results, vst, samples, means, manifest, directory):
    """Mean VST over time for the most significant genes, with each sample as a dot."""
    time_info = manifest["time"]
    levels, position = time_positions(time_info)
    significant = results[results["significant"]]
    chosen = significant if len(significant) else results[results["pvalue"].notna()]
    genes = list(chosen.sort_values(["padj", "pvalue"], kind="stable").index[:TRAJECTORY_GENES])

    columns = 4
    rows = max(1, int(np.ceil(len(genes) / columns)))
    figure, grid = plt.subplots(rows, columns, figsize=(11, 2.6 * rows + 0.8), squeeze=False)
    means = means.assign(time=means["time"].astype(str), condition=means["condition"].fillna("").astype(str))
    sample_conditions = samples["condition"].astype(str) if "condition" in samples.columns else pd.Series("", index=samples.index)
    conditions = list(dict.fromkeys(means["condition"]))
    for axes, gene in zip(grid.flat, genes):
        for color, condition in zip(CONDITION_COLORS * 10, conditions):
            line = means[(means["gene_id"] == gene) & (means["condition"] == condition)]
            line = line.set_index("time").loc[[time for time in levels if time in set(line["time"])]]
            axes.plot([position[time] for time in line.index], line["mean_vst"], color=color, marker="o",
                      linewidth=1.5, markersize=4, label=condition or None)
            members = sample_conditions.index[sample_conditions == condition] if condition else samples.index
            members = [sample for sample in members if sample in vst.columns]
            axes.scatter([position[str(samples.loc[sample, "time"])] for sample in members],
                         vst.loc[gene, members], color=color, s=10, alpha=0.5, linewidth=0)
        axes.set_title(f"{gene} (padj {results.loc[gene, 'padj']:.2g})", fontsize=8)
        axes.set_xticks([position[time] for time in levels])
        axes.set_xticklabels(levels, fontsize=7)
        axes.tick_params(axis="y", labelsize=7)
    for axes in list(grid.flat)[len(genes):]:
        axes.axis("off")
    if conditions != [""]:
        grid.flat[0].legend(fontsize=7)
    figure.supxlabel(f"Time ({time_info['column']})", fontsize=9)
    figure.supylabel("VST expression", fontsize=9)
    title = "Most significant genes over time" if len(significant) else "No significant genes: lowest p-values shown"
    figure.suptitle(f"{title} (lines: group means; dots: samples)", fontsize=10)
    save(figure, directory / OUTPUTS["trajectories"])


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
    results = read_table(directory / manifest["outputs"]["results"])
    results["significant"] = results["significant"].astype(str).str.upper().eq("TRUE")
    vst = read_table(directory / manifest["outputs"]["vst_all"])
    samples = read_table(directory / manifest["outputs"]["size_factors"])

    if manifest.get("time"):
        levels = [str(level) for level in manifest["time"]["levels"]]
        samples["time"] = samples["time"].astype(str)
        condition_name = (manifest.get("contrast") or {}).get("variable", "condition")
        plot_time_pca(vst, samples, levels, condition_name, directory)
        means = pd.read_csv(directory / manifest["outputs"]["group_means"], sep="\t", keep_default_na=False, na_values=["NA"])
        means["gene_id"] = means["gene_id"].astype(str)
        plot_trajectories(results, vst, samples, means, manifest, directory)
        # Plots that only some runs draw: never leave one from an earlier run.
        for key in ("cluster_trajectories", "cluster_selection", "gp_curves", "gp_differences"):
            (directory / OUTPUTS[key]).unlink(missing_ok=True)
        if (manifest.get("clustering") or {}).get("status") == "completed":
            clusters = pd.read_csv(directory / manifest["outputs"]["gene_clusters"], sep="\t", dtype={"gene_id": str})
            profiles = pd.read_csv(directory / manifest["outputs"]["cluster_profiles"], sep="\t",
                                   keep_default_na=False, na_values=["NA"])
            selection = pd.read_csv(directory / manifest["outputs"]["cluster_selection"], sep="\t")
            plot_clusters(clusters, profiles, means, manifest, directory)
            plot_cluster_selection(selection, manifest, directory)
            if (manifest.get("gaussian_process") or {}).get("status") == "completed":
                read_gp = lambda key: pd.read_csv(directory / manifest["outputs"][key], sep="\t",
                                                  keep_default_na=False, na_values=["NA"])
                plot_gp_curves(read_gp("gp_curves"), read_gp("gp_points"), manifest, directory)
                if "gp_differences" in manifest["outputs"]:
                    plot_gp_differences(pd.read_csv(directory / manifest["outputs"]["gp_differences"], sep="\t"), manifest, directory)
        return

    contrast = f"log2 fold change, {manifest['contrast']['log2_fold_change']}"
    conditions = samples["condition"].rename(manifest["contrast"]["variable"])
    plot_pca(vst, conditions, directory)
    plot_ma(results, contrast, directory)
    plot_volcano(results, contrast, manifest["contrast"]["test_level"], directory)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
