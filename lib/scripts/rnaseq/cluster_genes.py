"""Group the significant genes of a time-course run by the shape of their change.

Usage:
    python cluster_genes.py RESULTS_DIR [--clusters N] [--silhouette-baseline]

Reads manifest.json, deseq2_results.tsv and group_means_vst.tsv from a
completed time-course deseq2_analysis.R run. Each significant gene becomes one
vector of its mean VST values, ordered by condition then time point (for a
condition-by-time run both conditions' series are joined). Each vector is
z-scored, so genes are grouped by shape rather than expression level, and
clustered with k-means. Without --clusters the number of clusters is the k
from 2 to 10 with the highest mean silhouette.

With --silhouette-baseline the silhouette is also compared with a random
baseline: each gene's values are shuffled across its groups (which keeps the
gene's z-scores, and so its shape, but scrambles its timing so genes no longer
share when they change), the shuffled data is clustered with the same k, and
the silhouettes of several shuffles are averaged. Similar shapes still group
together by chance, so the baseline is not 0; a difference near 0 means the
clusters are no better separated than randomly timed patterns.

A Gaussian process comparison (condition_time_gp) has no significant genes
and must not use the condition labels before its test. It keeps the most
variable genes across all samples (--variable-percent, or by default 1000
genes, or half of them if that is fewer) and clusters each gene's z-scored
values in every individual sample rather than its group means, so genes
that move in opposite directions in the two conditions still differ.
Its cluster_profiles.tsv still summarizes each cluster by condition and time
point, and the manifest gains a "gene_selection" section.

Writes gene_clusters.tsv, cluster_profiles.tsv and cluster_selection.tsv and
adds a "clustering" section to manifest.json. Too few genes is not an error:
the manifest records why clustering was skipped. A two-condition run is left
unchanged.
"""
import argparse
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.spatial.distance import cdist

MIN_GENES = 20
MIN_GROUPS = 3
MAX_CLUSTERS = 10
MIN_CLUSTERS = 2
RESTARTS = 10
MAX_ITERATIONS = 300
SEED = 20261108
# Silhouette needs every pairwise distance; above this many genes it is
# computed on a fixed random sample (3000^2 doubles is about 72 MB).
SILHOUETTE_SAMPLE = 3000
BASELINE_SHUFFLES = 5
FLAT_SD = 1e-8
OUTPUTS = {"gene_clusters": "gene_clusters.tsv", "cluster_profiles": "cluster_profiles.tsv",
           "cluster_selection": "cluster_selection.tsv"}
# condition_time_gp: without a chosen percent, keep this many of the most
# variable genes, or this share of them when that is fewer.
GP_TYPE = "condition_time_gp"
AUTO_VARIABLE_GENES = 1000
AUTO_MAX_SHARE = 0.5
GROUP_METHOD = "k-means on z-scored mean VST per group (condition and time point)"
SAMPLE_METHOD = "k-means on z-scored VST values in every sample (condition labels not used)"


def gene_matrix(means, genes, time_levels):
    """Genes x groups matrix of mean VST, groups ordered by condition then time.

    Returns the matrix (DataFrame) and the list of (condition, time) columns.
    """
    means = means.assign(gene_id=means["gene_id"].astype(str), time=means["time"].astype(str),
                         condition=means["condition"].fillna("").astype(str))
    means = means[means["gene_id"].isin(set(genes))]
    conditions = list(dict.fromkeys(means["condition"]))
    order = {time: index for index, time in enumerate(time_levels)}
    columns = sorted({(condition, time) for condition, time in zip(means["condition"], means["time"])},
                     key=lambda key: (conditions.index(key[0]), order.get(key[1], len(order))))
    matrix = means.pivot_table(index="gene_id", columns=["condition", "time"], values="mean_vst", aggfunc="first")
    matrix = matrix.reindex(columns=pd.MultiIndex.from_tuples(columns, names=["condition", "time"]))
    return matrix.reindex([gene for gene in genes if gene in matrix.index]), columns


def zscore(matrix):
    """Center and scale each row. Rows that are flat or incomplete are dropped.

    Returns (scaled rows, boolean mask of kept rows).
    """
    values = np.asarray(matrix, dtype=float)
    complete = np.isfinite(values).all(axis=1)
    sd = np.zeros(len(values))
    sd[complete] = values[complete].std(axis=1)
    keep = complete & (sd > FLAT_SD)
    kept = values[keep]
    return (kept - kept.mean(axis=1, keepdims=True)) / sd[keep][:, None], keep


def kmeans_plus_plus(data, k, rng):
    centers = [data[rng.integers(len(data))]]
    for _ in range(1, k):
        distance = cdist(data, np.array(centers), "sqeuclidean").min(axis=1)
        total = distance.sum()
        if total <= 0:
            centers.append(data[rng.integers(len(data))])
        else:
            centers.append(data[rng.choice(len(data), p=distance / total)])
    return np.array(centers)


def kmeans_once(data, k, rng):
    centers = kmeans_plus_plus(data, k, rng)
    labels = None
    for _ in range(MAX_ITERATIONS):
        distance = cdist(data, centers, "sqeuclidean")
        new_labels = distance.argmin(axis=1)
        if labels is not None and np.array_equal(new_labels, labels):
            break
        labels = new_labels
        for cluster in range(k):
            members = data[labels == cluster]
            if len(members):
                centers[cluster] = members.mean(axis=0)
            else:
                # Reseed an empty cluster at the point farthest from its center.
                farthest = distance[np.arange(len(data)), labels].argmax()
                centers[cluster] = data[farthest]
                labels[farthest] = cluster
    spread = float(((data - centers[labels]) ** 2).sum())
    return labels, centers, spread


def kmeans_best(data, k, seed=SEED, restarts=RESTARTS):
    """The lowest within-cluster spread over several k-means++ starts."""
    rng = np.random.default_rng([seed, k])
    best = None
    for _ in range(restarts):
        result = kmeans_once(data, k, rng)
        if best is None or result[2] < best[2] - 1e-12:
            best = result
    return best


def silhouette(data, labels):
    """Mean silhouette: (b - a) / max(a, b) per point; points alone in a cluster score 0."""
    labels = np.asarray(labels)
    clusters = np.unique(labels)
    if len(clusters) < 2:
        return float("nan")
    distance = cdist(data, data)
    onehot = (labels[:, None] == clusters[None, :]).astype(float)
    sums = distance @ onehot
    sizes = onehot.sum(axis=0)
    own = np.searchsorted(clusters, labels)
    own_size = sizes[own]
    a = np.where(own_size > 1, sums[np.arange(len(data)), own] / np.maximum(own_size - 1, 1), 0.0)
    other = sums / sizes
    other[np.arange(len(data)), own] = np.inf
    b = other.min(axis=1)
    scores = np.where(own_size > 1, (b - a) / np.maximum(np.maximum(a, b), 1e-300), 0.0)
    return float(scores.mean())


def silhouette_sample(n, seed=SEED):
    """Indices the silhouette is computed on: all of them, or a fixed random sample."""
    if n <= SILHOUETTE_SAMPLE:
        return np.arange(n)
    return np.sort(np.random.default_rng(seed).choice(n, SILHOUETTE_SAMPLE, replace=False))


def shuffled_silhouette(data, k, seed=SEED, shuffles=BASELINE_SHUFFLES):
    """Mean silhouette of k-means with k clusters on copies of data whose rows are shuffled."""
    rng = np.random.default_rng([seed, k, 1])
    sample = silhouette_sample(len(data), seed)
    scores = []
    for index in range(shuffles):
        shuffled = rng.permuted(data, axis=1)
        labels = kmeans_best(shuffled, k, seed=seed + 1 + index)[0]
        scores.append(silhouette(shuffled[sample], labels[sample]))
    return float(np.mean(scores))


def choose_k(data, requested=None, seed=SEED):
    """Cluster for each candidate k and pick one.

    Returns (chosen k, {k: (labels, centers, spread)}, selection DataFrame, sampled).
    """
    candidates = range(MIN_CLUSTERS, min(MAX_CLUSTERS, len(data) - 1) + 1)
    if requested is not None and requested not in candidates:
        candidates = sorted(set(candidates) | {requested})
    sample = silhouette_sample(len(data), seed)
    sampled = len(data) > SILHOUETTE_SAMPLE
    fits, rows = {}, []
    for k in candidates:
        fits[k] = kmeans_best(data, k, seed)
        rows.append({"k": k, "silhouette": silhouette(data[sample], fits[k][0][sample]),
                     "within_cluster_spread": fits[k][2]})
    selection = pd.DataFrame(rows)
    chosen = requested if requested is not None else int(selection.loc[selection["silhouette"].idxmax(), "k"])
    selection["chosen"] = selection["k"].eq(chosen)
    return chosen, fits, selection, sampled


def relabel_by_size(labels):
    """Number clusters 1..k, largest first (ties by first appearance)."""
    labels = np.asarray(labels)
    sizes = pd.Series(labels).value_counts(sort=False)
    first = {label: int(np.argmax(labels == label)) for label in sizes.index}
    order = sorted(sizes.index, key=lambda label: (-sizes[label], first[label]))
    mapping = {label: number for number, label in enumerate(order, start=1)}
    return np.array([mapping[label] for label in labels]), mapping


def cluster(means, genes, time_levels, requested=None, seed=SEED, baseline=False):
    """Cluster genes by their group means; returns a dict describing the result (see write_outputs)."""
    matrix, columns = gene_matrix(means, genes, time_levels)
    if len(columns) < MIN_GROUPS:
        return {"status": "skipped",
                "reason": f"Clustering needs at least {MIN_GROUPS} groups (condition and time point); this run has {len(columns)}."}
    return cluster_rows(matrix, columns, genes, requested, seed, baseline, "significant genes that vary over time")


def cluster_rows(matrix, columns, genes, requested, seed, baseline, kind, method=GROUP_METHOD):
    """k-means on the z-scored rows of matrix (genes x columns)."""
    scaled, keep = zscore(matrix)
    excluded = int((~keep).sum()) + len([gene for gene in genes if gene not in matrix.index])
    if len(scaled) < MIN_GENES:
        return {"status": "skipped", "excluded": excluded,
                "reason": f"Clustering needs at least {MIN_GENES} {kind}; this run has {len(scaled)}."}
    chosen, fits, selection, sampled = choose_k(scaled, requested, seed)
    raw_labels, centers, _ = fits[chosen]
    labels, mapping = relabel_by_size(raw_labels)
    ordered_centers = np.empty_like(centers)
    for raw, number in mapping.items():
        ordered_centers[number - 1] = centers[raw]
    return {"status": "completed", "genes": list(matrix.index[keep]), "scaled": scaled, "labels": labels,
            "centers": ordered_centers, "columns": columns, "selection": selection, "chosen": chosen,
            "requested": requested, "sampled": sampled, "excluded": excluded, "method": method,
            # The (condition, time) groups the profiles and plots summarize the clusters by.
            "groups": columns, "profile": scaled,
            "shuffled_silhouette": shuffled_silhouette(scaled, chosen, seed) if baseline else None}


# ---- condition_time_gp: label-blind gene selection and clustering ----------
# Nothing here reads the condition labels, so shuffling them within a time
# point changes neither the genes nor the clusters. gp_condition_test.py relies
# on that to calibrate its test by shuffling labels.

def variable_gene_count(total, percent=None):
    """How many of total genes to keep: percent of them, or by default
    AUTO_VARIABLE_GENES unless that is more than AUTO_MAX_SHARE of them."""
    if percent is not None:
        share = percent / 100
    else:
        share = min(AUTO_VARIABLE_GENES / total, AUTO_MAX_SHARE) if total else 0
    return min(total, max(1, int(np.floor(total * share + 0.5)))) if total else 0


def select_variable(vst, percent=None):
    """The most variable genes across all samples, as (genes, variances, summary).
    Ties keep the input order."""
    variance = vst.var(axis=1, ddof=1)
    kept = variable_gene_count(len(variance), percent)
    order = np.argsort(-variance.to_numpy(), kind="stable")[:kept]
    genes = list(variance.index[order])
    summary = {"method": "highest variance of VST values across all samples",
               "genes_after_prefilter": int(len(variance)), "kept": int(kept),
               "percent": round(100 * kept / len(variance), 2) if len(variance) else 0.0,
               "chosen_by": "user" if percent is not None else "automatic"}
    if percent is not None:
        summary["requested_percent"] = percent
    return genes, variance, summary


def sample_matrix(vst, samples, genes, time_levels):
    """Genes x samples VST values, samples ordered by time point then name."""
    order = {time: index for index, time in enumerate(time_levels)}
    chosen = sorted((sample for sample in samples.index if sample in vst.columns),
                    key=lambda sample: (order.get(str(samples.loc[sample, "time"]), len(order)), sample))
    return vst.loc[[gene for gene in genes if gene in vst.index], chosen]


def group_profile(means, genes, time_levels):
    """Each gene's mean VST per (condition, time) group, z-scored across the groups
    (as plot_results.plot_clusters draws them); NaN rows for genes flat across groups."""
    matrix, columns = gene_matrix(means, genes, time_levels)
    values = matrix.reindex(genes).to_numpy(dtype=float)
    sd = values.std(axis=1, keepdims=True)
    with np.errstate(invalid="ignore", divide="ignore"):
        scaled = np.where(sd > FLAT_SD, (values - values.mean(axis=1, keepdims=True)) / sd, np.nan)
    return scaled, columns


def cluster_samples(vst, samples, means, genes, time_levels, requested=None, seed=SEED, baseline=False):
    """Cluster genes by their z-scored values in every sample (not group means), so genes
    that rise in the same samples group together even when their time-point averages are flat."""
    matrix = sample_matrix(vst, samples, genes, time_levels)
    result = cluster_rows(matrix, list(matrix.columns), genes, requested, seed, baseline,
                          "selected genes that vary across samples", SAMPLE_METHOD)
    if result["status"] == "completed":
        result["profile"], result["groups"] = group_profile(means, result["genes"], time_levels)
    return result


def write_outputs(result, results, means, directory):
    genes, labels, scaled = result["genes"], result["labels"], result["scaled"]
    distance = np.sqrt(((scaled - result["centers"][labels - 1]) ** 2).sum(axis=1))
    table = pd.DataFrame({"gene_id": genes, "cluster": labels, "distance_to_center": distance})
    extra = [column for column in ("padj", "max_abs_log2FC", "log2FoldChange", "variance") if column in results.columns]
    table = table.join(results[extra], on="gene_id")
    table = table[["gene_id", "cluster", *extra, "distance_to_center"]].sort_values(["cluster", "distance_to_center"], kind="stable")
    table.to_csv(directory / OUTPUTS["gene_clusters"], sep="\t", index=False, na_rep="NA")

    time_values = (means.assign(time=means["time"].astype(str)).drop_duplicates("time")
                   .set_index("time")["time_value"].to_dict())
    rows = []
    profile = result["profile"]
    for number in range(1, result["chosen"] + 1):
        members = profile[labels == number]
        for index, (condition, time) in enumerate(result["groups"]):
            column = members[:, index]
            column = column[np.isfinite(column)]
            rows.append({"cluster": number, "condition": condition, "time": time,
                         "time_value": time_values.get(time, np.nan), "n_genes": int((labels == number).sum()),
                         "mean_z": column.mean() if len(column) else np.nan,
                         "sd_z": column.std(ddof=1) if len(column) > 1 else np.nan})
    pd.DataFrame(rows).to_csv(directory / OUTPUTS["cluster_profiles"], sep="\t", index=False, na_rep="NA")
    result["selection"].to_csv(directory / OUTPUTS["cluster_selection"], sep="\t", index=False, na_rep="NA")


def summary(result):
    if result["status"] != "completed":
        return {key: result[key] for key in ("status", "reason", "excluded") if key in result}
    chosen = result["selection"].set_index("k").loc[result["chosen"]]
    sizes = np.bincount(result["labels"], minlength=result["chosen"] + 1)[1:]
    baseline = {}
    if result.get("shuffled_silhouette") is not None:
        actual, shuffled = float(chosen["silhouette"]), result["shuffled_silhouette"]
        baseline = {"silhouette_baseline": {"k": int(result["chosen"]), "actual": round(actual, 4),
                                            "shuffled_mean": round(shuffled, 4),
                                            "difference": round(actual - shuffled, 4),
                                            "shuffles": BASELINE_SHUFFLES}}
    return {
        "status": "completed",
        "method": result["method"],
        "groups": [{"condition": condition, "time": time} for condition, time in result["groups"]],
        "genes_clustered": len(result["genes"]),
        "genes_excluded": result["excluded"],
        "clusters": int(result["chosen"]),
        "chosen_by": "user" if result["requested"] is not None else "silhouette",
        "silhouette": round(float(chosen["silhouette"]), 4),
        "silhouette_sampled_genes": SILHOUETTE_SAMPLE if result["sampled"] else None,
        "cluster_sizes": [int(size) for size in sizes],
        "seed": SEED,
        **baseline,
    }


def write_json_atomically(data, path):
    partial = path.with_name(path.name + ".partial")
    partial.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(partial, path)


def main(results_dir, requested=None, baseline=False, percent=None):
    directory = Path(results_dir)
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("status") != "completed":
        raise SystemExit("The differential expression results are incomplete; nothing was clustered.")
    if not manifest.get("time") or "group_means" not in manifest.get("outputs", {}):
        return
    if requested is not None and not MIN_CLUSTERS <= requested <= MAX_CLUSTERS:
        raise SystemExit(f"The number of clusters must be from {MIN_CLUSTERS} to {MAX_CLUSTERS}.")
    gp_type = manifest.get("experiment_type") == GP_TYPE
    if percent is not None and not gp_type:
        raise SystemExit("--variable-percent applies only to a Gaussian process comparison (condition_time_gp).")
    if percent is not None and not 0 < percent <= 100:
        raise SystemExit("The percent of most variable genes to keep must be more than 0 and at most 100.")

    results = pd.read_csv(directory / manifest["outputs"]["results"], sep="\t", index_col="gene_id")
    results.index = results.index.astype(str)
    means = pd.read_csv(directory / manifest["outputs"]["group_means"], sep="\t", keep_default_na=False, na_values=["NA"])
    levels = [str(level) for level in manifest["time"]["levels"]]
    if gp_type:
        vst = pd.read_csv(directory / manifest["outputs"]["vst_all"], sep="\t", index_col=0)
        vst.index = vst.index.astype(str)
        samples = pd.read_csv(directory / manifest["outputs"]["size_factors"], sep="\t", index_col=0, dtype={"time": str})
        genes, variance, manifest["gene_selection"] = select_variable(vst, percent)
        results = results.join(variance.rename("variance"))
        result = cluster_samples(vst, samples, means, genes, levels, requested, baseline=baseline)
    else:
        manifest.pop("gene_selection", None)
        significant = results.index[results["significant"].astype(str).str.upper().eq("TRUE")]
        result = cluster(means, list(significant), levels, requested, baseline=baseline)
    if result["status"] == "completed":
        write_outputs(result, results, means, directory)
        manifest["outputs"].update(OUTPUTS)
    else:
        # Never leave files from an earlier run beside a skipped clustering.
        for key, name in OUTPUTS.items():
            manifest["outputs"].pop(key, None)
            (directory / name).unlink(missing_ok=True)
    manifest["clustering"] = summary(result)
    write_json_atomically(manifest, manifest_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_dir")
    parser.add_argument("--clusters", type=int)
    parser.add_argument("--silhouette-baseline", action="store_true",
                        help="also compare the silhouette with that of shuffled copies of the data")
    parser.add_argument("--variable-percent", type=float,
                        help="condition_time_gp only: keep this percent of the most variable genes "
                             f"(default: {AUTO_VARIABLE_GENES} genes, or {AUTO_MAX_SHARE:.0%} of them if that is fewer)")
    arguments = parser.parse_args()
    main(arguments.results_dir, arguments.clusters, arguments.silhouette_baseline, arguments.variable_percent)
