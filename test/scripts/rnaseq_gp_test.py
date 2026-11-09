"""Tests for lib/scripts/rnaseq/gp_trajectories.py.

The curve fitting is checked against known functions and, where GPy is
installed (as in the MicroNet Docker image), against GPy fitting every point.
No R is needed: the results folders are built directly.
"""
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "lib/scripts/rnaseq/gp_trajectories.py"
spec = importlib.util.spec_from_file_location("gp_trajectories", SCRIPT)
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)

try:
    import GPy
except ImportError:  # pragma: no cover - GPy is in the Docker image
    GPy = None

TIMES = np.array([0.0, 2.0, 6.0, 12.0, 24.0])


def truth(time):
    return 1.5 * np.sin(time / 6.0)


def replicate_points(replicates=3, noise=0.2, seed=0, function=truth, times=TIMES):
    rng = np.random.default_rng(seed)
    x = np.repeat(times, replicates)
    return x, function(x) + rng.normal(0, noise, len(x))


class CurveFitTest(unittest.TestCase):
    @unittest.skipUnless(GPy, "GPy is not installed; run these tests in the MicroNet Docker image.")
    def test_grouped_likelihood_and_curve_equal_gpy_on_every_point(self):
        x, y = replicate_points(replicates=7, noise=0.4, seed=1)
        fit = gp.Fit(x, y, min_lengthscale=1.0)
        fit.lengthscale, fit.signal_variance, fit.noise_variance = 5.0, 0.8, 0.15
        model = GPy.models.GPRegression(x[:, None], y[:, None], GPy.kern.RBF(1, variance=0.8, lengthscale=5.0), noise_var=0.15)
        self.assertAlmostEqual(fit.parameters()["log_likelihood"], float(model.log_likelihood()), places=4)
        grid = np.linspace(0, 24, 25)
        mean, variance = model.predict_noiseless(grid[:, None])
        ours_mean, ours_sd = fit.predict(grid)
        np.testing.assert_allclose(ours_mean, mean.ravel(), atol=1e-6)
        np.testing.assert_allclose(ours_sd, np.sqrt(variance.ravel()), atol=1e-6)

    def test_curve_recovers_a_known_function_and_its_band_covers_it(self):
        x, y = replicate_points(replicates=4, noise=0.25, seed=2)
        fit = gp.fit_gp(x, y)
        grid = np.linspace(0, 24, 100)
        mean, sd = fit.predict(grid)
        at_times = fit.predict(TIMES)[0]
        np.testing.assert_allclose(at_times, truth(TIMES), atol=0.35)
        covered = np.mean((mean - gp.Z95 * sd <= truth(grid)) & (truth(grid) <= mean + gp.Z95 * sd))
        self.assertGreaterEqual(covered, 0.9)

    def test_pure_noise_gives_a_flat_curve(self):
        x, y = replicate_points(replicates=5, noise=1.0, seed=3, function=lambda time: 0 * time)
        mean, sd = gp.fit_gp(x, y).predict(np.linspace(0, 24, 50))
        self.assertLess(np.ptp(mean), 0.5)
        self.assertTrue(np.all(np.abs(mean) < gp.Z95 * sd + 0.3))

    def test_lengthscale_never_drops_below_half_the_largest_gap(self):
        # Alternating values beg for a wiggly curve; the bound must hold.
        x, y = replicate_points(function=lambda time: np.where(np.isin(time, [2.0, 12.0]), 2.0, -2.0), noise=0.05)
        fit = gp.fit_gp(x, y)
        self.assertEqual(gp.min_lengthscale(x), 6.0)
        self.assertGreaterEqual(fit.lengthscale, 6.0 - 1e-9)

    def test_fitting_is_deterministic(self):
        x, y = replicate_points(seed=4)
        first, second = gp.fit_gp(x, y), gp.fit_gp(x, y)
        self.assertEqual(first.parameters(), second.parameters())

    def test_difference_adds_variances_and_finds_where_conditions_differ(self):
        grid = np.linspace(0, 24, 100)
        x, reference = replicate_points(seed=5, function=lambda time: 0 * time, noise=0.1)
        _, test = replicate_points(seed=6, function=lambda time: np.where(time >= 12, 2.0, 0.0) * (time / 24), noise=0.1)
        curves = {}
        for name, values in [("reference", reference), ("test", test)]:
            mean, sd = gp.fit_gp(x, values).predict(grid)
            curves[name] = pd.DataFrame({"time": grid, "mean": mean, "sd": sd})
        delta = gp.difference(curves["test"], curves["reference"])
        np.testing.assert_allclose(delta["sd"], np.hypot(curves["test"]["sd"], curves["reference"]["sd"]))
        intervals = gp.differing_intervals(delta)
        self.assertTrue(intervals)
        self.assertTrue(all(interval["direction"] == "higher" for interval in intervals))
        self.assertGreaterEqual(intervals[-1]["end"], 23.9)
        # Measured as unchanged up to 6; the change happens somewhere between 6 and 12.
        self.assertGreater(intervals[0]["start"], 4.0)

    def test_differing_intervals_split_by_direction(self):
        curve = pd.DataFrame({"time": np.arange(6.0), "lower": [0.1, 0.2, -1, -2, -3, -1],
                              "upper": [1, 1, 1, -0.5, -0.1, 1]})
        self.assertEqual(gp.differing_intervals(curve), [
            {"start": 0.0, "end": 1.0, "direction": "higher"},
            {"start": 3.0, "end": 4.0, "direction": "lower"},
        ])


def results_folder(directory, experiment_type="time_course", numeric=True, cluster_count=3, genes_per_cluster=8,
                   times=("0", "6", "24"), replicates=3, seed=7):
    """A minimal clustered results folder whose clusters follow known shapes."""
    rng = np.random.default_rng(seed)
    shapes = [np.array([0.0, 2.0, 0.0]), np.array([2.0, 1.0, 0.0]), np.array([0.0, 0.5, 2.0])][:cluster_count]
    conditions = ["control", "treated"] if experiment_type == "condition_by_time" else [""]
    samples = [(f"{condition or 's'}_t{time}_{replicate}", condition, time)
               for condition in conditions for time in times for replicate in range(replicates)]
    genes, cluster_of, vst = [], [], {}
    for number, shape in enumerate(shapes, start=1):
        for index in range(genes_per_cluster):
            gene = f"c{number}_g{index}"
            genes.append(gene)
            cluster_of.append(number)
            level = rng.uniform(5, 10)
            vst[gene] = [level + (shape[times.index(time)] if condition != "control" else 0.0) + rng.normal(0, 0.2)
                         for _, condition, time in samples]
    vst = pd.DataFrame(vst, index=[sample for sample, _, _ in samples]).T
    vst.index.name = "gene_id"
    vst.to_csv(directory / "vst_all.tsv", sep="\t")
    sheet = pd.DataFrame({"sample": [sample for sample, _, _ in samples], "time": [time for _, _, time in samples],
                          "size_factor": 1.0})
    if experiment_type == "condition_by_time":
        sheet.insert(1, "condition", [condition for _, condition, _ in samples])
    sheet.to_csv(directory / "size_factors.tsv", sep="\t", index=False)
    rows = []
    for gene in genes:
        for condition in conditions:
            for time in times:
                members = [sample for sample, sample_condition, sample_time in samples
                           if sample_condition == condition and sample_time == time]
                rows.append({"gene_id": gene, "condition": condition, "time": time,
                             "time_value": float(time) if numeric else "NA", "n_samples": len(members),
                             "mean_vst": vst.loc[gene, members].mean()})
    pd.DataFrame(rows).to_csv(directory / "group_means_vst.tsv", sep="\t", index=False)
    pd.DataFrame({"gene_id": genes, "cluster": cluster_of}).to_csv(directory / "gene_clusters.tsv", sep="\t", index=False)
    manifest = {
        "status": "completed", "experiment_type": experiment_type,
        "time": {"column": "time", "levels": list(times), "numeric_values": [float(time) for time in times] if numeric else None},
        "contrast": {"reference_level": "control", "test_level": "treated"} if experiment_type == "condition_by_time" else None,
        "clustering": {"status": "completed", "clusters": cluster_count,
                       "groups": [{"condition": condition, "time": time} for condition in conditions for time in times]},
        "outputs": {"results": "deseq2_results.tsv", "vst_all": "vst_all.tsv", "size_factors": "size_factors.tsv",
                    "group_means": "group_means_vst.tsv", "gene_clusters": "gene_clusters.tsv"},
    }
    (directory / "manifest.json").write_text(json.dumps(manifest))
    return manifest


class GpScriptTest(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="micronet-gp-"))

    def tearDown(self):
        shutil.rmtree(self.directory)

    def run_script(self):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.directory)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.directory / "manifest.json").read_text())

    def test_time_course_writes_one_curve_per_cluster(self):
        results_folder(self.directory)
        manifest = self.run_script()
        self.assertEqual(manifest["gaussian_process"]["status"], "completed")
        self.assertEqual(manifest["gaussian_process"]["conditions"], [""])
        self.assertNotIn("difference", manifest["gaussian_process"])
        self.assertNotIn("gp_differences", manifest["outputs"])
        for key in ("gp_points", "gp_curves", "gp_fits"):
            self.assertTrue((self.directory / manifest["outputs"][key]).is_file(), key)
        points = pd.read_csv(self.directory / "cluster_gp_points.tsv", sep="\t")
        self.assertEqual(len(points), 3 * 9, "one point per sample per cluster")
        fits = pd.read_csv(self.directory / "cluster_gp_fits.tsv", sep="\t")
        self.assertEqual(fits["n_genes"].tolist(), [8, 8, 8])
        self.assertTrue((fits["lengthscale"] >= 9.0 - 1e-9).all())
        curves = pd.read_csv(self.directory / "cluster_gp_curves.tsv", sep="\t", keep_default_na=False)
        self.assertEqual(len(curves), 3 * gp.GRID_POINTS)
        # Cluster 1 peaks at the middle time point: its curve there is above both ends.
        peak = curves[curves["cluster"] == 1].set_index("time")["mean"]
        self.assertGreater(peak.loc[6.0:6.3].iloc[0], max(peak.iloc[0], peak.iloc[-1]) + 0.5)
        self.assertFalse(list(self.directory.glob("*.partial")))

    def test_condition_by_time_adds_differences_that_find_the_planted_changes(self):
        results_folder(self.directory, experiment_type="condition_by_time")
        manifest = self.run_script()
        difference = manifest["gaussian_process"]["difference"]
        self.assertEqual((difference["reference_level"], difference["test_level"]), ("control", "treated"))
        self.assertEqual(manifest["gaussian_process"]["conditions"], ["control", "treated"])
        differences = pd.read_csv(self.directory / "cluster_gp_differences.tsv", sep="\t")
        self.assertEqual(len(differences), 3 * gp.GRID_POINTS)
        # Cluster 1: treated is 2 higher at 6 and equal at 0 and 24. Curves are in z-scores: the
        # six group means (0, 0, 0 and 0, 2, 0) have standard deviation sqrt(5/9), so 2 becomes
        # 2 / sqrt(5/9). At the measured times the difference matches; between 6 and 24 the smooth
        # curve may overshoot (see the README).
        one = differences[differences["cluster"] == 1].set_index("time")["difference"]
        at = lambda time: one.iloc[np.abs(one.index - time).argmin()]
        self.assertAlmostEqual(at(6.0), 2.0 / np.sqrt(5 / 9), delta=0.4)
        self.assertAlmostEqual(at(0.0), 0.0, delta=0.4)
        self.assertAlmostEqual(at(24.0), 0.0, delta=0.4)
        self.assertTrue(any(interval["start"] <= 6 <= interval["end"] and interval["direction"] == "higher"
                            for interval in difference["intervals"]["1"]))

    def test_non_numeric_times_skip_the_curves_with_a_reason(self):
        results_folder(self.directory, numeric=False)
        manifest = self.run_script()
        self.assertEqual(manifest["gaussian_process"]["status"], "skipped")
        self.assertIn("not numbers", manifest["gaussian_process"]["reason"])
        self.assertFalse((self.directory / "cluster_gp_curves.tsv").exists())

    def test_too_few_time_points_skip_the_curves(self):
        results_folder(self.directory, times=("0", "24"))
        manifest = self.run_script()
        self.assertEqual(manifest["gaussian_process"]["status"], "skipped")
        self.assertIn("need at least 3", manifest["gaussian_process"]["reason"])

    def test_unclustered_runs_skip_and_stale_curves_are_removed(self):
        results_folder(self.directory)
        self.run_script()
        manifest = json.loads((self.directory / "manifest.json").read_text())
        manifest["clustering"] = {"status": "skipped", "reason": "too few genes"}
        (self.directory / "manifest.json").write_text(json.dumps(manifest))
        manifest = self.run_script()
        self.assertEqual(manifest["gaussian_process"]["status"], "skipped")
        self.assertIn("not clustered", manifest["gaussian_process"]["reason"])
        for key, name in gp.OUTPUTS.items():
            self.assertNotIn(key, manifest["outputs"])
            self.assertFalse((self.directory / name).exists(), name)

    def test_two_condition_results_are_left_alone(self):
        manifest = {"status": "completed", "experiment_type": "two_condition", "outputs": {}}
        (self.directory / "manifest.json").write_text(json.dumps(manifest))
        self.assertEqual(self.run_script(), manifest)


if __name__ == "__main__":
    unittest.main()
