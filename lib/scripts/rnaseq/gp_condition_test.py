"""Test each gene cluster for a difference between two conditions over time (B-GREAT style).

Usage:
    python gp_condition_test.py RESULTS_DIR [--treatment-start T] [--permutations B]

For a condition_time_gp run that cluster_genes.py has clustered. The approach
follows B-GREAT (Tonner et al., Genome Research 2017): two Gaussian process
models of a cluster's mean expression are compared with an approximate Bayes
factor, and the score is calibrated by shuffling the condition labels.

Cluster values. Each sample gets one value per cluster: the mean, over the
cluster's genes, of the gene's VST value z-scored across all samples (as
cluster_genes.py clusters them). The sample is the independent replicate.

Treatment timing is the user's, never guessed from the data:
  - from the start (no --treatment-start): every test-condition sample is
    treated, and the conditions may differ at every time point;
  - added at time T (--treatment-start T): a test-condition sample counts as
    treated only after T. Samples at or before T are a shared baseline, and
    the treatment effect is pinned to 0 at T.

Models.
  M0, no difference: one curve f(t) for every sample (RBF + noise, the Fit of
      gp_trajectories.py). It does not use the labels.
  M1, a difference: reference = f(t), treated = f(t) + g(t), where g is a
      second RBF Gaussian process (pinned to 0 at T when T is given).
Both are fitted by maximum marginal likelihood; log_bf = log L(M1) - log L(M0).

Calibration. M1 has more freedom, so log_bf is almost always above 0 and is
not read on its own. Its null distribution comes from relabeling: within each
time point (after T only) and block of covariate values, which samples are
"test" is reassigned, keeping how many there are. All relabelings are used
when there are at most B of them, otherwise B random ones. p is the share of
relabelings scoring at least as high as the real labels, and clusters are
adjusted together with Benjamini-Hochberg. This is valid because the genes
and clusters were chosen without the labels (cluster_genes.py), so they are
the same under every relabeling.

Writes cluster_gp_points.tsv, cluster_gp_curves.tsv, cluster_gp_fits.tsv,
cluster_gp_differences.tsv and cluster_gp_tests.tsv, and a "gaussian_process"
section (with a "test" part) in manifest.json.
"""
import argparse
import importlib.util
import itertools
import json
import os
from math import comb, prod
from pathlib import Path

# Thousands of fits on matrices of a few rows each: threaded linear algebra only
# adds overhead (it was about 10 times slower), so use one thread.
for variable in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(variable, "1")

import numpy as np
import pandas as pd
from scipy.linalg import cho_factor, cho_solve
from scipy.optimize import minimize
from scipy.stats import false_discovery_control

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gp_trajectories", HERE / "gp_trajectories.py")
gp_trajectories = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp_trajectories)
cluster_genes = gp_trajectories.cluster_genes

Fit, rbf, min_lengthscale = gp_trajectories.Fit, gp_trajectories.rbf, gp_trajectories.min_lengthscale
Z95, VARIANCE_BOUNDS, GRID_POINTS = gp_trajectories.Z95, gp_trajectories.VARIANCE_BOUNDS, gp_trajectories.GRID_POINTS
GP_TYPE = cluster_genes.GP_TYPE
DEFAULT_PERMUTATIONS = 999
PERMUTATION_LIMITS = (99, 9999)
SEED = cluster_genes.SEED
TOLERANCE = 1e-9
OUTPUTS = {"gp_points": "cluster_gp_points.tsv", "gp_curves": "cluster_gp_curves.tsv", "gp_fits": "cluster_gp_fits.tsv",
           "gp_differences": "cluster_gp_differences.tsv", "gp_tests": "cluster_gp_tests.tsv"}


# ---- Data -------------------------------------------------------------------

def cluster_values(vst, genes):
    """Mean over genes of each gene's z-score across samples (one value per sample)."""
    values = vst.loc[[gene for gene in genes if gene in vst.index]].to_numpy(dtype=float)
    sd = values.std(axis=1, keepdims=True)
    usable = sd[:, 0] > cluster_genes.FLAT_SD
    z = (values[usable] - values[usable].mean(axis=1, keepdims=True)) / sd[usable]
    return z.mean(axis=0), int(usable.sum())


def eligible_samples(times, treatment_start):
    """Samples whose label can matter: after the treatment, or every sample when treated from the start."""
    times = np.asarray(times, dtype=float)
    return np.ones(len(times), dtype=bool) if treatment_start is None else times > treatment_start


def effective_labels(is_test, times, treatment_start):
    """1 for samples that were treated when measured."""
    return (np.asarray(is_test, dtype=bool) & eligible_samples(times, treatment_start)).astype(float)


def check_timing(times, is_test, treatment_start):
    """Raises ValueError when the timing leaves nothing to compare."""
    unique = np.unique(times)
    if treatment_start is not None and not unique[0] <= treatment_start < unique[-1]:
        raise ValueError(f"The treatment time ({treatment_start:g}) must be at or after the first time point "
                         f"({unique[0]:g}) and before the last ({unique[-1]:g}).")
    labels = effective_labels(is_test, times, treatment_start).astype(bool)
    eligible = eligible_samples(times, treatment_start)
    if not labels.any() or not (eligible & ~labels).any():
        raise ValueError("Both conditions need samples after the treatment time to be compared.")
    if len(unique) < gp_trajectories.MIN_TIMES:
        raise ValueError(f"The samples cover {len(unique)} time points; the test needs at least {gp_trajectories.MIN_TIMES}.")


# ---- Model M1: shared curve plus a treatment effect --------------------------

def effect_kernel(a, b, lengthscale, variance, treatment_start):
    """Covariance of the treatment effect g. Pinned to 0 at treatment_start (and before it) when given:
    the RBF covariance conditioned on g(treatment_start) = 0."""
    return effect_kernel_with_derivative(a, b, lengthscale, variance, treatment_start)[0]


def effect_kernel_with_derivative(a, b, lengthscale, variance, treatment_start):
    """(covariance, its derivative with respect to log lengthscale)."""
    a, b = np.asarray(a, dtype=float), np.asarray(b, dtype=float)
    squared = np.subtract.outer(a, b) ** 2 / lengthscale ** 2
    shape = np.exp(-0.5 * squared)
    if treatment_start is None:
        return variance * shape, variance * shape * squared
    to_start_a, to_start_b = (a - treatment_start) ** 2 / lengthscale ** 2, (b - treatment_start) ** 2 / lengthscale ** 2
    start_a, start_b = np.exp(-0.5 * to_start_a), np.exp(-0.5 * to_start_b)
    after = np.outer(a > treatment_start, b > treatment_start)
    k = variance * (shape - np.outer(start_a, start_b))
    dk = variance * (shape * squared - np.outer(start_a * to_start_a, start_b) - np.outer(start_a, start_b * to_start_b))
    return np.where(after, k, 0.0), np.where(after, dk, 0.0)


class ShiftFit:
    """reference = f(t), treated = f(t) + g(t); f and g RBF Gaussian processes plus Gaussian noise.

    As in gp_trajectories.Fit, the likelihood is computed exactly from each
    group's mean, count and within-group sum of squares, where a group is the
    samples sharing a time point and a label (treated when measured or not).
    """

    def __init__(self, times, labels, values, treatment_start, minimum_lengthscale, start=None):
        times, labels, values = (np.asarray(array, dtype=float) for array in (times, labels, values))
        keys, inverse, self.n = np.unique(np.column_stack([times, labels]), axis=0, return_inverse=True,
                                          return_counts=True)
        inverse = inverse.ravel()
        self.x, self.c = keys[:, 0], keys[:, 1]
        self.mean_values = np.bincount(inverse, weights=values) / self.n
        self.within = float(((values - self.mean_values[inverse]) ** 2).sum())
        self.total = len(values)
        self.treatment_start = treatment_start
        span = float(np.ptp(times))
        self.span = span
        lengthscale_bounds = (minimum_lengthscale, 10.0 * span)
        self.bounds = [lengthscale_bounds, VARIANCE_BOUNDS, lengthscale_bounds, VARIANCE_BOUNDS, VARIANCE_BOUNDS]
        self.start = start
        self.parameters_ = None

    def covariance(self, lengthscale, signal_variance, effect_lengthscale, effect_variance):
        shared = rbf(self.x, self.x, lengthscale, signal_variance)
        effect = effect_kernel(self.x, self.x, effect_lengthscale, effect_variance, self.treatment_start)
        return shared + np.outer(self.c, self.c) * effect

    def negative_log_likelihood(self, lengthscale, signal_variance, effect_lengthscale, effect_variance, noise_variance):
        return self.objective(np.log([lengthscale, signal_variance, effect_lengthscale, effect_variance, noise_variance]))[0]

    def objective(self, log_parameters):
        """(negative log likelihood, its gradient with respect to the log parameters)."""
        lengthscale, signal_variance, effect_lengthscale, effect_variance, noise_variance = np.exp(log_parameters)
        squared = np.subtract.outer(self.x, self.x) ** 2 / lengthscale ** 2
        shared = signal_variance * np.exp(-0.5 * squared)
        labels = np.outer(self.c, self.c)
        effect, effect_slope = effect_kernel_with_derivative(self.x, self.x, effect_lengthscale, effect_variance,
                                                             self.treatment_start)
        noise = np.diag(noise_variance / self.n)
        covariance = shared + labels * effect + noise + 1e-10 * np.eye(len(self.x))
        try:
            factor = cho_factor(covariance, lower=True)
        except np.linalg.LinAlgError:
            return 1e12, np.zeros(5)
        alpha = cho_solve(factor, self.mean_values)
        groups = len(self.x)
        value = float(0.5 * self.mean_values @ alpha + np.log(np.diag(factor[0])).sum()
                      + 0.5 * groups * np.log(2 * np.pi)
                      + 0.5 * (self.total - groups) * np.log(2 * np.pi * noise_variance)
                      + self.within / (2 * noise_variance) + 0.5 * np.log(self.n).sum())
        weight = cho_solve(factor, np.eye(groups)) - np.outer(alpha, alpha)
        slopes = (shared * squared, shared, labels * effect_slope, labels * effect, noise)
        gradient = np.array([0.5 * float((weight * slope).sum()) for slope in slopes])
        gradient[4] += 0.5 * (self.total - groups) - self.within / (2 * noise_variance)
        return value, gradient

    def starts(self):
        """A fixed set of starting points that does not depend on the labels, so every
        relabeling is optimized the same way."""
        low, high = self.bounds[0]
        middle = max(low, self.span / 2)
        spread = float(np.clip(max(float(np.var(self.mean_values)), 1e-3), *VARIANCE_BOUNDS))
        noise = self.within / (self.total - len(self.x)) if self.total > len(self.x) else 0.1
        noise = float(np.clip(noise, *VARIANCE_BOUNDS))
        points = [[low, spread, low, spread / 2, noise], [middle, spread, middle, spread / 2, noise]]
        if self.start is not None:
            points.append(list(self.start))
        return [np.log(np.clip(point, [bound[0] for bound in self.bounds], [bound[1] for bound in self.bounds]))
                for point in points]

    def optimize(self):
        best = None
        for start in self.starts():
            result = minimize(self.objective, start, jac=True, method="L-BFGS-B", bounds=np.log(self.bounds))
            if best is None or result.fun < best.fun - 1e-9:
                best = result
        self.parameters_ = tuple(float(value) for value in np.exp(best.x))
        return self

    @property
    def log_likelihood(self):
        return -self.negative_log_likelihood(*self.parameters_)

    def predict(self, grid):
        """Posterior mean and sd on grid of f (reference), f + g (treated) and g (the difference)."""
        lengthscale, signal_variance, effect_lengthscale, effect_variance, noise_variance = self.parameters_
        grid = np.asarray(grid, dtype=float)
        covariance = self.covariance(lengthscale, signal_variance, effect_lengthscale, effect_variance)
        factor = cho_factor(covariance + np.diag(noise_variance / self.n) + 1e-10 * np.eye(len(self.x)), lower=True)
        shared = rbf(grid, self.x, lengthscale, signal_variance)
        effect = effect_kernel(grid, self.x, effect_lengthscale, effect_variance, self.treatment_start) * self.c[None, :]
        effect_prior = np.diag(effect_kernel(grid, grid, effect_lengthscale, effect_variance, self.treatment_start))
        treated_grid = grid if self.treatment_start is None else grid[grid > self.treatment_start]
        on = np.isin(grid, treated_grid).astype(float)
        result = {}
        for name, cross, prior in (("reference", shared, np.full(len(grid), signal_variance)),
                                   ("difference", effect, effect_prior),
                                   ("test", shared + effect * on[:, None], signal_variance + effect_prior * on)):
            mean = cross @ cho_solve(factor, self.mean_values)
            variance = prior - np.einsum("ij,ji->i", cross, cho_solve(factor, cross.T))
            result[name] = (mean, np.sqrt(np.maximum(variance, 0.0)))
        return result

    def lengthscale_limits(self):
        """"lower"/"upper"/"" for the shared and the effect lengthscale (as Fit.lengthscale_limit)."""
        names = []
        for value, bound in ((self.parameters_[0], self.bounds[0]), (self.parameters_[2], self.bounds[2])):
            names.append(next((name for name, limit in zip(("lower", "upper"), bound) if np.isclose(value, limit, rtol=1e-4)), ""))
        return names


# ---- Relabelings --------------------------------------------------------------

def relabelings(is_test, times, blocks, treatment_start, count, seed=SEED):
    """Test-condition masks to score: (masks, exact, total distinct relabelings).

    Within each (time, block) of eligible samples, the test samples are reassigned,
    keeping how many there are. Samples at or before the treatment time never change.
    """
    is_test = np.asarray(is_test, dtype=bool)
    eligible = eligible_samples(times, treatment_start)
    keys = np.array([f"{time!r}\t{block}" for time, block in zip(np.asarray(times, dtype=float), np.asarray(blocks, dtype=str))])
    cells = []
    for key in dict.fromkeys(keys[eligible]):
        members = np.flatnonzero(eligible & (keys == key))
        tested = int(is_test[members].sum())
        if 0 < tested < len(members):
            cells.append((members, tested))
    total = prod(comb(len(members), tested) for members, tested in cells)
    if total <= count:
        masks = []
        for choice in itertools.product(*(itertools.combinations(members, tested) for members, tested in cells)):
            mask = is_test.copy()
            for members, chosen in zip((members for members, _ in cells), choice):
                mask[members] = False
                mask[list(chosen)] = True
            masks.append(mask)
        return masks, True, total
    rng = np.random.default_rng([seed, 7])
    masks = []
    for _ in range(count):
        mask = is_test.copy()
        for members, tested in cells:
            mask[members] = False
            mask[rng.choice(members, tested, replace=False)] = True
        masks.append(mask)
    return masks, False, total


def permutation_p(observed, null, exact):
    """Exact: the share of all relabelings (the real one among them) scoring >= observed.
    Sampled: (1 + number >= observed) / (1 + number drawn)."""
    at_least = int((np.asarray(null) >= observed - TOLERANCE).sum())
    return at_least / len(null) if exact else (1 + at_least) / (1 + len(null))


def pre_treatment_gap(values, is_test, times, treatment_start):
    """Mean test - reference value at the shared time points (at or before treatment), or NaN."""
    if treatment_start is None:
        return float("nan")
    gaps = []
    for time in np.unique(times[times <= treatment_start]):
        here = times == time
        if (here & is_test).any() and (here & ~is_test).any():
            gaps.append(values[here & is_test].mean() - values[here & ~is_test].mean())
    return float(np.mean(gaps)) if gaps else float("nan")


# ---- One cluster ----------------------------------------------------------------

def test_cluster(values, times, is_test, blocks, treatment_start, masks, exact, grid):
    """Fit M0 and M1, score the real labels and every relabeling; returns a dict of results."""
    minimum = min_lengthscale(times)
    null_fit = Fit(times, values, minimum).optimize()
    start = (null_fit.lengthscale, null_fit.signal_variance, minimum, 1e-3, null_fit.noise_variance)

    def fit(mask):
        return ShiftFit(times, effective_labels(mask, times, treatment_start), values, treatment_start,
                        minimum, start).optimize()

    # M0 does not use the labels, so its likelihood is the same for every relabeling.
    shared_log_likelihood = null_fit.parameters()["log_likelihood"]
    alternative = fit(is_test)
    log_bf = alternative.log_likelihood - shared_log_likelihood
    null_scores = [log_bf if np.array_equal(mask, is_test) else fit(mask).log_likelihood - shared_log_likelihood
                   for mask in masks]
    return {"null_fit": null_fit, "fit": alternative, "log_bf": float(log_bf),
            "p_value": permutation_p(log_bf, null_scores, exact), "curves": alternative.predict(grid),
            "pre_treatment_gap": pre_treatment_gap(values, is_test, times, treatment_start)}


# ---- Whole run --------------------------------------------------------------------

def test_all(manifest, clusters, vst, samples, treatment_start, permutations):
    """Returns (points, curves, fits, differences, tests, summary)."""
    contrast = manifest["contrast"]
    reference, test = contrast["reference_level"], contrast["test_level"]
    time_info = manifest["time"]
    time_values = dict(zip((str(level) for level in time_info["levels"]), (float(value) for value in time_info["numeric_values"])))
    samples = samples[samples.index.isin(vst.columns)]
    names = list(samples.index)
    times = np.array([time_values[str(time)] for time in samples["time"]], dtype=float)
    is_test = (samples["condition"].astype(str) == test).to_numpy()
    blocks = samples["block"].astype(str).to_numpy() if "block" in samples.columns else np.full(len(names), "all")
    check_timing(times, is_test, treatment_start)
    vst = vst[names]

    masks, exact, total = relabelings(is_test, times, blocks, treatment_start, permutations)
    grid = np.linspace(times.min(), times.max(), GRID_POINTS)
    if treatment_start is not None:
        grid = np.unique(np.concatenate([grid, [treatment_start]]))
    alpha = float((manifest.get("parameters") or {}).get("alpha", 0.05))

    points, curves, fits, differences, rows, intervals = [], [], [], [], [], {}
    for number in sorted(clusters["cluster"].unique()):
        members = list(clusters.loc[clusters["cluster"] == number, "gene_id"].astype(str))
        values, used = cluster_values(vst, members)
        result = test_cluster(values, times, is_test, blocks, treatment_start, masks, exact, grid)
        number = int(number)
        points.append(pd.DataFrame({"cluster": number, "condition": samples["condition"].astype(str).to_numpy(),
                                    "sample": names, "time": times, "mean_z": values}))
        for condition, key in ((reference, "reference"), (test, "test")):
            mean, sd = result["curves"][key]
            curves.append(pd.DataFrame({"cluster": number, "condition": condition, "time": grid, "mean": mean, "sd": sd,
                                        "lower": mean - Z95 * sd, "upper": mean + Z95 * sd}))
        mean, sd = result["curves"]["difference"]
        delta = pd.DataFrame({"cluster": number, "time": grid, "difference": mean, "sd": sd,
                              "lower": mean - Z95 * sd, "upper": mean + Z95 * sd})
        differences.append(delta)
        intervals[str(number)] = gp_trajectories.differing_intervals(delta)
        null_fit, fit = result["null_fit"], result["fit"]
        shared_limit, effect_limit = fit.lengthscale_limits()
        fits.append({"cluster": number, "model": "M0 (one shared curve)", "n_genes": used, "n_points": len(values),
                     "lengthscale": null_fit.lengthscale, "signal_variance": null_fit.signal_variance,
                     "effect_lengthscale": np.nan, "effect_variance": np.nan, "noise_variance": null_fit.noise_variance,
                     "log_likelihood": null_fit.parameters()["log_likelihood"],
                     "lengthscale_at_limit": null_fit.lengthscale_limit(), "effect_lengthscale_at_limit": ""})
        lengthscale, signal, effect_lengthscale, effect_variance, noise = fit.parameters_
        fits.append({"cluster": number, "model": "M1 (shared curve + treatment effect)", "n_genes": used,
                     "n_points": len(values), "lengthscale": lengthscale, "signal_variance": signal,
                     "effect_lengthscale": effect_lengthscale, "effect_variance": effect_variance,
                     "noise_variance": noise, "log_likelihood": fit.log_likelihood,
                     "lengthscale_at_limit": shared_limit, "effect_lengthscale_at_limit": effect_limit})
        first = intervals[str(number)][0]["start"] if intervals[str(number)] else np.nan
        rows.append({"cluster": number, "n_genes": used, "log_bf": result["log_bf"], "permutations": len(masks),
                     "exact": exact, "p_value": result["p_value"], "diverges_at": first,
                     **({"pre_treatment_gap": result["pre_treatment_gap"]} if treatment_start is not None else {})})

    tests = pd.DataFrame(rows)
    tests.insert(tests.columns.get_loc("p_value") + 1, "q_value", false_discovery_control(tests["p_value"], method="bh"))
    tests.insert(tests.columns.get_loc("q_value") + 1, "significant", tests["q_value"] < alpha)
    fit_table = pd.DataFrame(fits)
    minimum_p = (1 / total) if exact else 1 / (1 + len(masks))
    warnings = []
    if minimum_p >= alpha:
        warnings.append(f"With these replicates there are only {total} distinct ways to relabel the samples, so the "
                        f"smallest possible p-value is {minimum_p:.3g}, which cannot fall below {alpha:g}. "
                        "More replicates after the treatment are needed to find a significant difference.")
    summary = {
        "status": "completed",
        "method": "Gaussian process regression on each sample's mean z-score over the cluster's genes",
        "kernel": "RBF + Gaussian noise, maximum likelihood; lengthscale at least half the largest gap between time points",
        "band": "95% interval of the cluster's mean curve",
        "conditions": [reference, test],
        "curves": 2 * len(rows),
        "min_lengthscale": min_lengthscale(times),
        "lengthscale_at_limits": {"lower": int((fit_table["lengthscale_at_limit"] == "lower").sum()),
                                  "upper": int((fit_table["lengthscale_at_limit"] == "upper").sum())},
        "difference": {"test_level": test, "reference_level": reference, "intervals": intervals},
        "test": {
            "method": "approximate Bayes factor (B-GREAT): one shared curve (M0) vs a shared curve plus a "
                      "treatment effect (M1), calibrated by relabeling samples",
            "treatment_timing": "from_start" if treatment_start is None else "added",
            "treatment_start": treatment_start,
            "relabelings": len(masks), "distinct_relabelings": total, "exact": exact,
            "min_possible_p": minimum_p, "alpha": alpha,
            "shuffled_within": "time point" + ("" if (blocks == "all").all() else " and covariate values")
                               + (f", after time {treatment_start:g} only" if treatment_start is not None else ""),
            "significant_clusters": int(tests["significant"].sum()),
            "warnings": warnings,
        },
    }
    return (pd.concat(points, ignore_index=True), pd.concat(curves, ignore_index=True), fit_table,
            pd.concat(differences, ignore_index=True), tests, summary)


def main(results_dir, treatment_start=None, permutations=DEFAULT_PERMUTATIONS):
    if not PERMUTATION_LIMITS[0] <= permutations <= PERMUTATION_LIMITS[1]:
        raise SystemExit(f"The number of permutations must be from {PERMUTATION_LIMITS[0]} to {PERMUTATION_LIMITS[1]}.")
    directory = Path(results_dir)
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("status") != "completed":
        raise SystemExit("The normalization results are incomplete; nothing was tested.")
    if manifest.get("experiment_type") != GP_TYPE:
        raise SystemExit("gp_condition_test.py applies only to a Gaussian process comparison (condition_time_gp).")
    for name in OUTPUTS.values():
        (directory / name).unlink(missing_ok=True)
    for key in OUTPUTS:
        manifest["outputs"].pop(key, None)

    if (manifest.get("clustering") or {}).get("status") != "completed":
        gp_trajectories.skip(manifest, "The genes were not clustered, so there are no clusters to test.")
    else:
        read = lambda key, **options: pd.read_csv(directory / manifest["outputs"][key], sep="\t", **options)
        clusters = read("gene_clusters", dtype={"gene_id": str})
        vst = read("vst_all", index_col=0)
        vst.index = vst.index.astype(str)
        samples = read("size_factors", index_col=0, dtype={"time": str, "condition": str, "block": str},
                       keep_default_na=False)
        try:
            *tables, summary = test_all(manifest, clusters, vst, samples, treatment_start, permutations)
        except ValueError as error:
            gp_trajectories.skip(manifest, str(error))
        else:
            for key, table in zip(("gp_points", "gp_curves", "gp_fits", "gp_differences", "gp_tests"), tables):
                table.to_csv(directory / OUTPUTS[key], sep="\t", index=False, na_rep="NA")
            manifest["outputs"].update(OUTPUTS)
            manifest["gaussian_process"] = summary
    cluster_genes.write_json_atomically(manifest, manifest_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_dir")
    parser.add_argument("--treatment-start", type=float,
                        help="the time the treatment was added; leave out when samples were treated from the start")
    parser.add_argument("--permutations", type=int, default=DEFAULT_PERMUTATIONS,
                        help=f"relabelings to score when there are more than this many (default {DEFAULT_PERMUTATIONS})")
    arguments = parser.parse_args()
    main(arguments.results_dir, arguments.treatment_start, arguments.permutations)
