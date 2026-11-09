"""Smooth Gaussian process curves over time for each gene cluster.

Usage:
    python gp_trajectories.py RESULTS_DIR

Reads manifest.json, gene_clusters.tsv, vst_all.tsv, size_factors.tsv and
group_means_vst.tsv from a time-course run that cluster_genes.py has
clustered. For each cluster (and, in a condition-by-time run, each
condition) every member gene's sample values are z-scored with the gene's own
center and scale (as in clustering) and averaged over the cluster's genes,
giving one value per sample. Genes measured in the same sample share that
sample's errors, so the sample, not the gene, is the independent replicate.
One Gaussian process (RBF kernel plus Gaussian noise, the model AMiGA fits
with GPy) is fitted to those per-sample values at their numeric times; its
noise is the replicate-to-replicate spread. The curve and its 95% band
describe the cluster's mean pattern. A condition-by-time run also gets the
difference between the two conditions' curves.

Every point lies at one of a few time points, so the exact GP likelihood and
posterior depend only on each time point's mean, count and within-time sum of
squares. They are computed from those directly (identical to fitting GPy on
all points, which test/scripts/rnaseq_gp_test.py checks) on matrices the size
of the number of time points.

Writes cluster_gp_points.tsv, cluster_gp_curves.tsv, cluster_gp_fits.tsv and, for condition-by-time,
cluster_gp_differences.tsv, and adds a "gaussian_process" section to
manifest.json. Non-numeric time points or missing clusters are not errors:
the manifest records why no curves were fitted.
"""
import importlib.util
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.linalg import cho_factor, cho_solve
from scipy.optimize import minimize

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("cluster_genes", HERE / "cluster_genes.py")
cluster_genes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cluster_genes)

GRID_POINTS = 100
MIN_TIMES = 3
VARIANCE_BOUNDS = (1e-6, 100.0)
Z95 = 1.959963984540054
OUTPUTS = {"gp_points": "cluster_gp_points.tsv", "gp_curves": "cluster_gp_curves.tsv", "gp_fits": "cluster_gp_fits.tsv",
           "gp_differences": "cluster_gp_differences.tsv"}


def gene_scaling(means, genes, time_levels):
    """Each gene's center and scale across its group means, as cluster_genes.zscore uses."""
    matrix, _ = cluster_genes.gene_matrix(means, genes, time_levels)
    values = matrix.to_numpy(dtype=float)
    return pd.DataFrame({"center": values.mean(axis=1), "scale": values.std(axis=1)}, index=matrix.index)


def cluster_points(members, vst, samples, scaling, time_values, condition=None):
    """One point per sample: (samples, times, mean z-score over the cluster's genes, genes used)."""
    chosen = samples.index if condition is None else samples.index[samples["condition"].astype(str) == condition]
    chosen = [sample for sample in chosen if sample in vst.columns]
    genes = [gene for gene in members if gene in scaling.index and scaling.loc[gene, "scale"] > cluster_genes.FLAT_SD
             and gene in vst.index]
    z = (vst.loc[genes, chosen].to_numpy(dtype=float) - scaling.loc[genes, ["center"]].to_numpy()) \
        / scaling.loc[genes, ["scale"]].to_numpy()
    times = np.array([time_values[str(samples.loc[sample, "time"])] for sample in chosen], dtype=float)
    return chosen, times, z.mean(axis=0), genes


def rbf(a, b, lengthscale, variance):
    return variance * np.exp(-0.5 * (np.subtract.outer(a, b) / lengthscale) ** 2)


class Fit:
    """A GP with an RBF kernel and Gaussian noise, fitted to points at a few distinct times.

    Grouping the points by time is exact: the likelihood of all points equals
    the likelihood of the time means (noise variance / count at each time)
    plus a within-time term that depends only on the noise variance.
    """

    def __init__(self, times, values, min_lengthscale):
        times, values = np.asarray(times, dtype=float), np.asarray(values, dtype=float)
        self.x, inverse, self.n = np.unique(times, return_inverse=True, return_counts=True)
        self.mean_values = np.bincount(inverse, weights=values) / self.n
        self.within = float(((values - self.mean_values[inverse]) ** 2).sum())
        self.total = len(values)
        self.span = self.x[-1] - self.x[0]
        self.bounds = [(min_lengthscale, 10.0 * self.span), VARIANCE_BOUNDS, VARIANCE_BOUNDS]
        self.lengthscale = self.signal_variance = self.noise_variance = None

    def _factor(self, lengthscale, signal_variance, noise_variance):
        covariance = rbf(self.x, self.x, lengthscale, signal_variance) + np.diag(noise_variance / self.n)
        return cho_factor(covariance + 1e-10 * np.eye(len(self.x)), lower=True)

    def negative_log_likelihood(self, lengthscale, signal_variance, noise_variance):
        factor = self._factor(lengthscale, signal_variance, noise_variance)
        alpha = cho_solve(factor, self.mean_values)
        groups = len(self.x)
        return float(0.5 * self.mean_values @ alpha + np.log(np.diag(factor[0])).sum()
                     + 0.5 * groups * np.log(2 * np.pi)
                     + 0.5 * (self.total - groups) * np.log(2 * np.pi * noise_variance)
                     + self.within / (2 * noise_variance) + 0.5 * np.log(self.n).sum())

    def optimize(self):
        """Maximum likelihood over log parameters, from a fixed set of starting points (no randomness)."""
        low, high = self.bounds[0]
        spread = max(float(np.var(self.mean_values)), 1e-3)
        noise = self.within / (self.total - len(self.x)) if self.total > len(self.x) else 0.1
        noise = float(np.clip(noise, *VARIANCE_BOUNDS))
        objective = lambda log: self.negative_log_likelihood(*np.exp(log))
        best = None
        for lengthscale in (low, np.sqrt(low * max(high / 10, low)), max(low, self.span / 2)):
            for signal in (spread, 1.0):
                start = np.log([lengthscale, signal, noise])
                result = minimize(objective, start, method="L-BFGS-B", bounds=np.log(self.bounds))
                if best is None or result.fun < best.fun - 1e-9:
                    best = result
        self.lengthscale, self.signal_variance, self.noise_variance = (float(value) for value in np.exp(best.x))
        return self

    def predict(self, grid):
        """Mean and standard deviation of the mean curve (no observation noise) at the given times."""
        grid = np.asarray(grid, dtype=float)
        factor = self._factor(self.lengthscale, self.signal_variance, self.noise_variance)
        cross = rbf(grid, self.x, self.lengthscale, self.signal_variance)
        mean = cross @ cho_solve(factor, self.mean_values)
        variance = self.signal_variance - np.einsum("ij,ji->i", cross, cho_solve(factor, cross.T))
        return mean, np.sqrt(np.maximum(variance, 0.0))

    def parameters(self):
        return {"lengthscale": self.lengthscale, "signal_variance": self.signal_variance,
                "noise_variance": self.noise_variance,
                "log_likelihood": -self.negative_log_likelihood(self.lengthscale, self.signal_variance, self.noise_variance)}


def min_lengthscale(times):
    """Half the largest gap between consecutive time points, so the curve cannot sag back to
    the prior (zero) inside a long unmeasured stretch."""
    return 0.5 * float(np.diff(np.unique(times)).max())


def fit_gp(times, values):
    return Fit(times, values, min_lengthscale(times)).optimize()


def difference(test, reference):
    """Test minus reference curve; the fits are independent, so variances add."""
    sd = np.sqrt(test["sd"].to_numpy() ** 2 + reference["sd"].to_numpy() ** 2)
    value = test["mean"].to_numpy() - reference["mean"].to_numpy()
    return pd.DataFrame({"time": test["time"].to_numpy(), "difference": value, "sd": sd,
                         "lower": value - Z95 * sd, "upper": value + Z95 * sd})


def differing_intervals(curve):
    """Time ranges where the difference band excludes 0, as [start, end, direction]."""
    direction = np.where(curve["lower"] > 0, 1, np.where(curve["upper"] < 0, -1, 0))
    intervals, start = [], None
    times = curve["time"].to_numpy()
    for index, value in enumerate(direction):
        if start is None and value != 0:
            start = index
        if start is not None and (index == len(direction) - 1 or direction[index + 1] != value):
            if value != 0:
                intervals.append({"start": round(float(times[start]), 6), "end": round(float(times[index]), 6),
                                  "direction": "higher" if value > 0 else "lower"})
            start = None
    return intervals


def skip(manifest, reason):
    manifest["gaussian_process"] = {"status": "skipped", "reason": reason}


def fit_all(manifest, clusters, vst, samples, means):
    """Fit every cluster's curves; returns (curves, fits, differences or None, summary)."""
    time_info = manifest["time"]
    levels = [str(level) for level in time_info["levels"]]
    time_values = dict(zip(levels, (float(value) for value in time_info["numeric_values"])))
    conditions = [condition for condition in dict.fromkeys(means["condition"].fillna("").astype(str))]
    comparison = manifest["experiment_type"] == "condition_by_time"
    if comparison:
        contrast = manifest["contrast"]
        conditions = [contrast["reference_level"], contrast["test_level"]]
    elif conditions != [""]:
        conditions = [""]  # a time course on one condition: one curve over its samples
    for condition in conditions:
        members = samples.index if not condition else samples.index[samples["condition"].astype(str) == condition]
        present = {str(samples.loc[sample, "time"]) for sample in members}
        if len(present) < MIN_TIMES:
            label = f"Condition {condition}" if condition else "The samples"
            raise ValueError(f"{label} cover {len(present)} time points; Gaussian process curves need at least {MIN_TIMES}.")

    scaling = gene_scaling(means, list(clusters["gene_id"]), levels)
    grid = np.linspace(min(time_values.values()), max(time_values.values()), GRID_POINTS)
    points, curves, fits, differences, intervals = [], [], [], [], {}
    for number in sorted(clusters["cluster"].unique()):
        members = list(clusters.loc[clusters["cluster"] == number, "gene_id"])
        by_condition = {}
        for condition in conditions:
            chosen, times, values, used = cluster_points(members, vst, samples, scaling, time_values, condition or None)
            points.append(pd.DataFrame({"cluster": int(number), "condition": condition, "sample": chosen,
                                        "time": times, "mean_z": values}))
            fit = fit_gp(times, values)
            mean, sd = fit.predict(grid)
            curve = pd.DataFrame({"cluster": int(number), "condition": condition, "time": grid, "mean": mean, "sd": sd,
                                  "lower": mean - Z95 * sd, "upper": mean + Z95 * sd})
            by_condition[condition] = curve
            curves.append(curve)
            fits.append({"cluster": int(number), "condition": condition, "n_genes": len(used),
                         "n_points": len(values), **fit.parameters()})
        if comparison:
            reference, test = conditions
            delta = difference(by_condition[test], by_condition[reference])
            intervals[str(number)] = differing_intervals(delta)
            differences.append(delta.assign(cluster=int(number))[["cluster", "time", "difference", "sd", "lower", "upper"]])

    fit_table = pd.DataFrame(fits)
    summary = {
        "status": "completed",
        "method": "Gaussian process regression on each sample's mean z-score over the cluster's genes",
        "kernel": "RBF + Gaussian noise, maximum likelihood; lengthscale at least half the largest gap between time points",
        "band": "95% interval of the cluster's mean curve",
        "conditions": conditions,
        "curves": len(fits),
        "min_lengthscale": min_lengthscale(list(time_values.values())),
    }
    if comparison:
        summary["difference"] = {"test_level": conditions[1], "reference_level": conditions[0], "intervals": intervals}
    return (pd.concat(points, ignore_index=True), pd.concat(curves, ignore_index=True), fit_table,
            pd.concat(differences, ignore_index=True) if comparison else None, summary)


def main(results_dir):
    directory = Path(results_dir)
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("status") != "completed":
        raise SystemExit("The differential expression results are incomplete; no curves were fitted.")
    if not manifest.get("time"):
        return
    for name in OUTPUTS.values():
        (directory / name).unlink(missing_ok=True)
    for key in OUTPUTS:
        manifest["outputs"].pop(key, None)

    if not manifest["time"].get("numeric_values"):
        skip(manifest, "The time points are not numbers, so there is no time axis to draw curves on.")
    elif (manifest.get("clustering") or {}).get("status") != "completed":
        skip(manifest, "The genes were not clustered, so there are no clusters to draw curves for.")
    else:
        read = lambda key, **options: pd.read_csv(directory / manifest["outputs"][key], sep="\t", **options)
        clusters = read("gene_clusters", dtype={"gene_id": str})
        vst = read("vst_all", index_col=0)
        vst.index = vst.index.astype(str)
        samples = read("size_factors", index_col=0, dtype={"time": str, "condition": str})
        means = read("group_means", keep_default_na=False, na_values=["NA"])
        try:
            points, curves, fits, differences, summary = fit_all(manifest, clusters, vst, samples, means)
        except ValueError as error:
            skip(manifest, str(error))
        else:
            points.to_csv(directory / OUTPUTS["gp_points"], sep="\t", index=False)
            curves.to_csv(directory / OUTPUTS["gp_curves"], sep="\t", index=False)
            fits.to_csv(directory / OUTPUTS["gp_fits"], sep="\t", index=False)
            written = ["gp_points", "gp_curves", "gp_fits"]
            if differences is not None:
                differences.to_csv(directory / OUTPUTS["gp_differences"], sep="\t", index=False)
                written.append("gp_differences")
            manifest["outputs"].update({key: OUTPUTS[key] for key in written})
            manifest["gaussian_process"] = summary
    cluster_genes.write_json_atomically(manifest, manifest_path)


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
