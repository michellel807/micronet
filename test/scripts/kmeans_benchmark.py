"""Which rule should choose the number of k-means clusters? A benchmark.

Usage (in the MicroNet Docker image):
    python test/scripts/kmeans_benchmark.py [--seeds 3] [--out results.tsv]

Builds gene patterns with a known number of clusters, z-scores them the way
lib/scripts/rnaseq/cluster_genes.py does, fits k-means for k = 2..10 with
cluster_genes.kmeans_best, and asks several rules to pick k:

  silhouette          highest mean silhouette (MicroNet's rule before this study)
  silhouette_95       smallest k whose silhouette is within 95% of the highest
  calinski_harabasz   highest between/within spread ratio
  davies_bouldin      lowest Davies-Bouldin index
  gap                 gap statistic, Tibshirani's 1-SE rule (may pick k = 1)
  stability           largest k whose clusters reappear when 80% of genes are
                      re-clustered (mean adjusted Rand index >= 0.8)

Scenarios: true k from 2 to 8, three noise levels, 3 and 6 time points,
equal and unequal cluster sizes, continuous patterns with no real clusters,
and patterns from rnaseq_simulation.simulate_time_course (the example data's
model). Reports how often each rule finds the true k, how close its
clustering is to the truth (adjusted Rand index), and what it does when
there is nothing to find. Not part of the test suite.
"""
import argparse
import importlib.util
import os
import time
from itertools import product
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cluster_genes = load("cluster_genes", ROOT / "lib/scripts/rnaseq/cluster_genes.py")
simulation = load("rnaseq_simulation", ROOT / "test/scripts/rnaseq_simulation.py")

KS = range(2, 11)
METHODS = ["silhouette", "silhouette_95", "calinski_harabasz", "davies_bouldin", "gap", "stability"]


def adjusted_rand(truth, labels):
    table = pd.crosstab(np.asarray(truth), np.asarray(labels)).to_numpy().astype(float)
    pairs = lambda values: (values * (values - 1) / 2).sum()
    index, rows, columns = pairs(table), pairs(table.sum(axis=1)), pairs(table.sum(axis=0))
    expected = rows * columns / pairs(np.array([table.sum()]))
    maximum = (rows + columns) / 2
    return 1.0 if maximum == expected else (index - expected) / (maximum - expected)


# ---------- scenarios ----------

def zscore_rows(values):
    values = values - values.mean(axis=1, keepdims=True)
    return values / values.std(axis=1, keepdims=True)


def distinct_shapes(k, times, rng):
    """k clearly different z-scored shapes. With 3 times every z-scored shape lies on a circle,
    so space them evenly around it; otherwise draw at random and keep shapes that differ."""
    if times == 3:
        basis = zscore_rows(np.array([[1.0, 0.0, -1.0], [1.0, -2.0, 1.0]]))
        angles = rng.uniform(0, 2 * np.pi) + 2 * np.pi * np.arange(k) / k
        return zscore_rows(np.outer(np.cos(angles), basis[0]) + np.outer(np.sin(angles), basis[1]))
    shapes = []
    while len(shapes) < k:
        candidate = zscore_rows(rng.normal(size=(1, times)))[0]
        if all(np.corrcoef(candidate, shape)[0, 1] < 0.5 for shape in shapes):
            shapes.append(candidate)
    return np.array(shapes)


def planted_data(true_k, times, noise, sizes, seed, genes_per_cluster=50):
    rng = np.random.default_rng(seed)
    shapes = distinct_shapes(true_k, times, rng)
    if sizes == "equal":
        counts = np.full(true_k, genes_per_cluster)
    else:
        counts = np.maximum(8, rng.dirichlet(np.ones(true_k) * 0.7) * genes_per_cluster * true_k).astype(int)
    truth = np.repeat(np.arange(true_k), counts)
    scale = rng.uniform(0.3, 2.0, size=len(truth))
    values = rng.uniform(4, 12, size=(len(truth), 1)) + scale[:, None] * (shapes[truth] + rng.normal(0, noise, (len(truth), times)))
    return zscore_rows(values), truth


def continuous_data(times, seed, genes=300):
    """No real clusters: every gene has its own random shape."""
    rng = np.random.default_rng(seed)
    return zscore_rows(rng.normal(size=(genes, times))), None


def example_model_data(seed):
    """Group means from the example data's simulation model (true time profiles plus replicate noise),
    for the time-changing genes; the truth is each gene's up/flat/down pattern."""
    experiment = simulation.simulate_time_course(seed=seed, n_genes=2000)
    truth_table = experiment.truth[experiment.truth["kind"] == "time"]
    profile = truth_table[[f"reference_lfc_at_{time}" for time in (0, 6, 24)]].to_numpy()
    rng = np.random.default_rng(seed)
    values = profile + rng.normal(0, 0.25, profile.shape)  # mean of 6 replicates on the VST scale
    signs = np.sign(np.round(profile[:, 1:], 6)).astype(int)
    truth = pd.factorize([f"{a}{b}" for a, b in signs])[0]
    keep = np.isfinite(zscore_rows(values)).all(axis=1)
    return zscore_rows(values)[keep], truth[keep]


# ---------- criteria ----------

def calinski_harabasz(data, labels, centers):
    k, n = len(centers), len(data)
    within = ((data - centers[labels]) ** 2).sum()
    between = ((data - data.mean(axis=0)) ** 2).sum() - within
    return (between / (k - 1)) / (within / (n - k))


def davies_bouldin(data, labels, centers):
    spread = np.array([np.linalg.norm(data[labels == cluster] - centers[cluster], axis=1).mean() if np.any(labels == cluster) else 0.0
                       for cluster in range(len(centers))])
    separation = np.linalg.norm(centers[:, None] - centers[None, :], axis=2)
    np.fill_diagonal(separation, np.inf)
    return float(np.mean(np.max((spread[:, None] + spread[None, :]) / separation, axis=1)))


def log_within(data, k, restarts=3):
    if k == 1:
        return np.log(((data - data.mean(axis=0)) ** 2).sum())
    return np.log(cluster_genes.kmeans_best(data, k, restarts=restarts)[2])


def gap_choice(data, references=10, seed=0):
    rng = np.random.default_rng(seed)
    reference_sets = [zscore_rows(rng.normal(size=data.shape)) for _ in range(references)]
    ks = [1, *KS]
    gaps, errors = [], []
    for k in ks:
        reference = np.array([log_within(sample, k) for sample in reference_sets])
        gaps.append(reference.mean() - log_within(data, k))
        errors.append(reference.std() * np.sqrt(1 + 1 / references))
    for index in range(len(ks) - 1):
        if gaps[index] >= gaps[index + 1] - errors[index + 1]:
            return ks[index]
    return ks[-1]


def stability_scores(data, fits, subsamples=20, share=0.8, seed=0):
    rng = np.random.default_rng(seed)
    scores = {}
    for k in KS:
        agreement = []
        for _ in range(subsamples):
            chosen = np.sort(rng.choice(len(data), int(share * len(data)), replace=False))
            labels = cluster_genes.kmeans_best(data[chosen], k, seed=int(rng.integers(1 << 30)), restarts=3)[0]
            agreement.append(adjusted_rand(fits[k][0][chosen], labels))
        scores[k] = float(np.mean(agreement))
    return scores


def choose_all(data):
    """{method: (chosen k, labels)} plus seconds per method."""
    started = time.perf_counter()
    fits = {k: cluster_genes.kmeans_best(data, k) for k in KS}
    fit_time = time.perf_counter() - started
    choices, seconds = {}, {}

    started = time.perf_counter()
    silhouette = {k: cluster_genes.silhouette(data, fits[k][0]) for k in KS}
    seconds["silhouette"] = seconds["silhouette_95"] = time.perf_counter() - started + fit_time
    best = max(silhouette.values())
    choices["silhouette"] = max(KS, key=lambda k: silhouette[k])
    choices["silhouette_95"] = min(k for k in KS if silhouette[k] >= 0.95 * best)

    started = time.perf_counter()
    choices["calinski_harabasz"] = max(KS, key=lambda k: calinski_harabasz(data, *fits[k][:2]))
    seconds["calinski_harabasz"] = time.perf_counter() - started + fit_time
    started = time.perf_counter()
    choices["davies_bouldin"] = min(KS, key=lambda k: davies_bouldin(data, *fits[k][:2]))
    seconds["davies_bouldin"] = time.perf_counter() - started + fit_time

    started = time.perf_counter()
    choices["gap"] = gap_choice(data)
    seconds["gap"] = time.perf_counter() - started + fit_time

    started = time.perf_counter()
    stability = stability_scores(data, fits)
    stable = [k for k in KS if stability[k] >= 0.8]
    choices["stability"] = max(stable) if stable else max(KS, key=lambda k: stability[k])
    seconds["stability"] = time.perf_counter() - started + fit_time

    labels = {method: (fits[k][0] if k > 1 else np.zeros(len(data), dtype=int)) for method, k in choices.items()}
    return choices, labels, seconds, best, max(stability.values())


def run(scenario):
    name, true_k, times, noise, sizes, seed = scenario
    if name == "planted":
        data, truth = planted_data(true_k, times, noise, sizes, seed)
    elif name == "continuous":
        data, truth = continuous_data(times, seed)
    else:
        data, truth = example_model_data(seed)
        true_k = len(np.unique(truth))
    choices, labels, seconds, best_silhouette, best_stability = choose_all(data)
    rows = []
    for method in METHODS:
        rows.append({"scenario": name, "true_k": true_k, "times": times, "noise": noise, "sizes": sizes, "seed": seed,
                     "genes": len(data), "method": method, "chosen_k": choices[method],
                     "ari": adjusted_rand(truth, labels[method]) if truth is not None else np.nan,
                     "seconds": seconds[method], "best_silhouette": best_silhouette, "best_stability": best_stability})
    return rows


def summarize(table):
    planted = table[table["scenario"] == "planted"].assign(
        exact=lambda frame: frame["chosen_k"] == frame["true_k"],
        within_one=lambda frame: (frame["chosen_k"] - frame["true_k"]).abs() <= 1)
    lines = ["PLANTED CLUSTERS (true k known)", "Share of datasets where the rule picked the true k, within 1, and mean ARI to truth:"]
    overall = planted.groupby("method")[["exact", "within_one", "ari"]].mean().loc[METHODS]
    overall["seconds"] = planted.groupby("method")["seconds"].mean().loc[METHODS]
    lines.append(overall.round(3).to_string())
    for column in ["times", "noise", "true_k"]:
        lines += ["", f"Exact-k rate by {column}:",
                  planted.pivot_table(index="method", columns=column, values="exact", aggfunc="mean").loc[METHODS].round(2).to_string()]
    example = table[table["scenario"] == "example_model"]
    if len(example):
        lines += ["", "EXAMPLE DATA MODEL (true k = number of up/flat/down patterns)",
                  example.groupby("method")[["true_k", "chosen_k", "ari"]].mean().loc[METHODS].round(3).to_string()]
    continuous = table[table["scenario"] == "continuous"]
    if len(continuous):
        lines += ["", "NO REAL CLUSTERS (continuous random shapes): k chosen, and the best scores seen",
                  continuous.pivot_table(index="method", columns="times", values="chosen_k", aggfunc="mean").loc[METHODS].round(2).to_string(),
                  "Best silhouette on these: " + continuous.groupby("times")["best_silhouette"].agg(["min", "max"]).round(3).to_string(),
                  "Best silhouette on planted data (noise 0.3 / 0.6 / 1.0): "
                  + planted.groupby("noise")["best_silhouette"].median().round(3).to_string()]
    return "\n".join(lines)


def main(seeds, out):
    scenarios = [("planted", k, times, noise, sizes, seed)
                 for k, times, noise, sizes, seed in product([2, 3, 4, 5, 6, 8], [3, 6], [0.3, 0.6, 1.0], ["equal", "unequal"], range(seeds))]
    scenarios += [("continuous", 0, times, 0, "", seed) for times, seed in product([3, 6], range(seeds * 3))]
    scenarios += [("example_model", 0, 3, 0.25, "", seed) for seed in range(seeds * 2)]
    started = time.perf_counter()
    with Pool(min(len(scenarios), max(1, (os.cpu_count() or 2) - 2))) as pool:
        table = pd.DataFrame([row for rows in pool.map(run, scenarios) for row in rows])
    table.to_csv(out, sep="\t", index=False)
    report = summarize(table)
    Path(out).with_suffix(".txt").write_text(report + "\n")
    print(report)
    print(f"\n{len(scenarios)} datasets in {time.perf_counter() - started:.0f} s; rows in {out}")


if __name__ == "__main__":
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seeds", type=int, default=3)
    parser.add_argument("--out", default="kmeans_benchmark.tsv")
    arguments = parser.parse_args()
    main(arguments.seeds, arguments.out)
