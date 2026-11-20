"""Tests for lib/scripts/rnaseq/gp_condition_test.py (the B-GREAT style cluster test).

Needs NumPy, SciPy and pandas only. Cluster values are simulated directly.
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
from scipy.optimize import approx_fprime
from scipy.stats import multivariate_normal

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "lib/scripts/rnaseq/gp_condition_test.py"
spec = importlib.util.spec_from_file_location("gp_condition_test", SCRIPT)
gp_test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp_test)

TIMES = np.repeat([0.0, 6.0, 24.0], 6)
IS_TEST = np.tile([False] * 3 + [True] * 3, 3)
BLOCKS = np.full(len(TIMES), "all")


def full_log_likelihood(times, labels, values, treatment_start, parameters):
    """The Gaussian likelihood of every point, from the full covariance matrix (no grouping)."""
    lengthscale, signal, effect_lengthscale, effect_variance, noise = parameters
    covariance = (gp_test.rbf(times, times, lengthscale, signal)
                  + np.outer(labels, labels) * gp_test.effect_kernel(times, times, effect_lengthscale, effect_variance,
                                                                       treatment_start)
                  + noise * np.eye(len(times)))
    return multivariate_normal(np.zeros(len(times)), covariance, allow_singular=False).logpdf(values)


def simulate(effect=0.0, gap=0.0, treatment_start=None, times=TIMES, is_test=IS_TEST, noise=0.3, seed=0):
    """Cluster values: a shared rise over time, plus `effect` for treated samples after the treatment
    (growing linearly to the last time) and a constant `gap` between conditions at every time."""
    rng = np.random.default_rng(seed)
    shared = np.sin(times / times.max() * np.pi)
    start = times.min() if treatment_start is None else treatment_start
    growth = np.clip((times - start) / (times.max() - start), 0, 1)
    return shared + is_test * (effect * growth + gap) + rng.normal(0, noise, len(times))


class LikelihoodTest(unittest.TestCase):
    def test_grouped_likelihood_equals_the_full_likelihood_in_both_timing_modes(self):
        values = simulate(effect=1.0, seed=1)
        for treatment_start in (None, 6.0, 3.0, 0.0):
            labels = gp_test.effective_labels(IS_TEST, TIMES, treatment_start)
            fit = gp_test.ShiftFit(TIMES, labels, values, treatment_start, 9.0)
            for parameters in ([5.0, 0.8, 12.0, 0.4, 0.3], [30.0, 2.0, 9.0, 1.5, 0.1]):
                with self.subTest(treatment_start=treatment_start, parameters=parameters):
                    self.assertAlmostEqual(-fit.negative_log_likelihood(*parameters),
                                           full_log_likelihood(TIMES, labels, values, treatment_start, parameters), places=6)

    def test_the_gradient_matches_finite_differences(self):
        values = simulate(effect=1.0, seed=2)
        for treatment_start in (None, 6.0):
            fit = gp_test.ShiftFit(TIMES, gp_test.effective_labels(IS_TEST, TIMES, treatment_start), values,
                                   treatment_start, 9.0)
            point = np.log([7.0, 0.9, 15.0, 0.5, 0.2])
            numeric = approx_fprime(point, lambda log: fit.objective(log)[0], 1e-6)
            np.testing.assert_allclose(fit.objective(point)[1], numeric, atol=1e-4)

    def test_without_an_effect_variance_m1_is_m0(self):
        values = simulate(seed=3)
        null = gp_test.Fit(TIMES, values, 9.0).optimize()
        fit = gp_test.ShiftFit(TIMES, gp_test.effective_labels(IS_TEST, TIMES, None), values, None, 9.0)
        m0 = (null.lengthscale, null.signal_variance, 9.0, gp_test.VARIANCE_BOUNDS[0], null.noise_variance)
        self.assertAlmostEqual(-fit.negative_log_likelihood(*m0), null.parameters()["log_likelihood"], places=4)
        self.assertGreaterEqual(fit.optimize().log_likelihood, null.parameters()["log_likelihood"] - 1e-6)


class TimingTest(unittest.TestCase):
    def test_a_pinned_effect_is_zero_at_and_before_the_treatment(self):
        values = simulate(effect=2.0, treatment_start=6.0, seed=4)
        fit = gp_test.ShiftFit(TIMES, gp_test.effective_labels(IS_TEST, TIMES, 6.0), values, 6.0, 9.0).optimize()
        grid = np.linspace(0, 24, 49)
        curves = fit.predict(grid)
        before = grid <= 6.0
        np.testing.assert_allclose(curves["difference"][0][before], 0.0, atol=1e-10)
        np.testing.assert_allclose(curves["difference"][1][before], 0.0, atol=1e-6)
        np.testing.assert_allclose(curves["test"][0][before], curves["reference"][0][before], atol=1e-10)
        self.assertGreater(curves["difference"][0][-1], 1.0)

    def test_samples_count_as_treated_only_after_the_treatment(self):
        labels = gp_test.effective_labels(IS_TEST, TIMES, 6.0)
        self.assertEqual(labels.sum(), 3)
        self.assertTrue((TIMES[labels == 1] == 24).all())
        self.assertEqual(gp_test.effective_labels(IS_TEST, TIMES, None).sum(), 9)

    def test_a_treatment_time_outside_the_series_is_refused(self):
        for start, fragment in ((24.0, "before the last"), (30.0, "before the last"), (-1.0, "at or after the first")):
            with self.assertRaisesRegex(ValueError, fragment):
                gp_test.check_timing(TIMES, IS_TEST, start)
        gp_test.check_timing(TIMES, IS_TEST, 0.0)
        gp_test.check_timing(TIMES, IS_TEST, None)

    def test_the_gap_before_treatment_is_reported(self):
        values = np.where(IS_TEST, 1.0, 0.0) + (TIMES > 6) * 5
        self.assertAlmostEqual(gp_test.pre_treatment_gap(values, IS_TEST, TIMES, 6.0), 1.0)
        self.assertTrue(np.isnan(gp_test.pre_treatment_gap(values, IS_TEST, TIMES, None)))


class RelabelingTest(unittest.TestCase):
    def test_with_a_treatment_time_only_later_samples_are_relabeled_and_all_ways_are_used(self):
        masks, exact, total = gp_test.relabelings(IS_TEST, TIMES, BLOCKS, 6.0, 999)
        self.assertTrue(exact)
        self.assertEqual(total, 20)
        self.assertEqual(len({mask.tobytes() for mask in masks}), 20)
        for mask in masks:
            np.testing.assert_array_equal(mask[TIMES <= 6], IS_TEST[TIMES <= 6])
            self.assertEqual(mask[TIMES == 24].sum(), 3)
        self.assertTrue(any(np.array_equal(mask, IS_TEST) for mask in masks))

    def test_from_the_start_every_time_point_is_relabeled(self):
        masks, exact, total = gp_test.relabelings(IS_TEST, TIMES, BLOCKS, None, 999)
        self.assertFalse(exact)
        self.assertEqual((total, len(masks)), (8000, 999))
        for time in (0.0, 6.0, 24.0):
            self.assertTrue(all(mask[TIMES == time].sum() == 3 for mask in masks))
            self.assertTrue(any(not np.array_equal(mask[TIMES == time], IS_TEST[TIMES == time]) for mask in masks))
        again, _, _ = gp_test.relabelings(IS_TEST, TIMES, BLOCKS, None, 999)
        self.assertTrue(all(np.array_equal(a, b) for a, b in zip(masks, again)))

    def test_labels_move_only_within_a_block(self):
        blocks = np.tile(["a", "b", "a", "b", "a", "b"], 3)
        masks, exact, total = gp_test.relabelings(IS_TEST, TIMES, blocks, 6.0, 999)
        # At 24 h each block holds 3 samples: control/treated counts (2,1) and (1,2): 3 * 3 ways.
        self.assertEqual((total, exact), (9, True))
        for mask in masks:
            for block in ("a", "b"):
                here = (TIMES == 24) & (blocks == block)
                self.assertEqual(mask[here].sum(), IS_TEST[here].sum())

    def test_p_values(self):
        self.assertEqual(gp_test.permutation_p(2.0, [2.0, 1.0, 0.5, 3.0], exact=True), 0.5)
        self.assertEqual(gp_test.permutation_p(2.0, [1.0, 0.5, 3.0], exact=False), 0.5)
        self.assertEqual(gp_test.permutation_p(9.0, [1.0] * 99, exact=False), 0.01)


class CalibrationTest(unittest.TestCase):
    """The test finds real differences and is not fooled by noise."""
    TIMES4 = np.repeat([0.0, 6.0, 12.0, 24.0], 6)
    IS_TEST4 = np.tile([False] * 3 + [True] * 3, 4)

    def p_value(self, values, treatment_start, count=49):
        masks, exact, _ = gp_test.relabelings(self.IS_TEST4, self.TIMES4, np.full(24, "all"), treatment_start, count)
        grid = np.linspace(0, 24, 25)
        return gp_test.test_cluster(values, self.TIMES4, self.IS_TEST4, None, treatment_start, masks, exact, grid)

    def test_no_difference_gives_spread_out_p_values(self):
        p = [self.p_value(simulate(times=self.TIMES4, is_test=self.IS_TEST4, seed=seed), 6.0)["p_value"]
             for seed in range(24)]
        self.assertGreater(np.mean(p), 0.3)
        self.assertLessEqual(np.mean(np.array(p) <= 0.1), 0.25)

    def test_a_response_after_the_treatment_is_found(self):
        values = simulate(effect=2.0, treatment_start=6.0, times=self.TIMES4, is_test=self.IS_TEST4, seed=7)
        result = self.p_value(values, 6.0)
        self.assertEqual(result["p_value"], 0.02)  # the smallest possible with 49 relabelings
        self.assertGreater(result["log_bf"], 2)

    def test_from_the_start_a_gap_present_at_the_first_sample_is_found(self):
        values = simulate(gap=1.5, times=self.TIMES4, is_test=self.IS_TEST4, seed=8)
        self.assertEqual(self.p_value(values, None)["p_value"], 0.02)


class ScriptTest(unittest.TestCase):
    """The command-line script on a small condition_time_gp results folder."""

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="micronet-gp-test-"))
        rng = np.random.default_rng(11)
        samples = pd.DataFrame({"sample": [f"{'treated' if test else 'control'}_t{int(time)}_{index % 3 + 1}"
                                           for index, (time, test) in enumerate(zip(TIMES, IS_TEST))],
                                "condition": np.where(IS_TEST, "treated", "control"), "time": TIMES.astype(int),
                                "size_factor": 1.0, "block": "all"}).set_index("sample")
        rows, clusters = {}, []
        # Clusters 1 and 3 respond from 0 h on (by 24 h: +3 and -3); cluster 2 does not respond.
        for number, effect in ((1, 3.0), (2, 0.0), (3, -3.0)):
            for gene in range(10):
                name = f"c{number}_{gene:02d}"
                rows[name] = 8 + simulate(effect=effect, noise=0.8, seed=number * 100 + gene) \
                    + rng.normal(0, 0.1, len(TIMES))
                clusters.append({"gene_id": name, "cluster": number, "variance": 1.0, "distance_to_center": 0.1})
        pd.DataFrame.from_dict(rows, orient="index", columns=samples.index).rename_axis("gene_id").to_csv(
            self.directory / "vst_all.tsv", sep="\t")
        samples.to_csv(self.directory / "size_factors.tsv", sep="\t")
        pd.DataFrame(clusters).to_csv(self.directory / "gene_clusters.tsv", sep="\t", index=False)
        self.manifest = {"status": "completed", "experiment_type": "condition_time_gp", "parameters": {"alpha": 0.05},
                         "contrast": {"variable": "condition", "reference_level": "control", "test_level": "treated"},
                         "time": {"column": "time", "levels": ["0", "6", "24"], "numeric_values": [0, 6, 24]},
                         "clustering": {"status": "completed", "clusters": 3},
                         "outputs": {"vst_all": "vst_all.tsv", "size_factors": "size_factors.tsv",
                                     "gene_clusters": "gene_clusters.tsv"}}
        (self.directory / "manifest.json").write_text(json.dumps(self.manifest))

    def tearDown(self):
        shutil.rmtree(self.directory)

    def run_script(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.directory), *arguments], capture_output=True, text=True)

    def manifest_now(self):
        return json.loads((self.directory / "manifest.json").read_text())

    def test_writes_the_tables_and_the_test_summary(self):
        result = self.run_script("--treatment-start", "6")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.manifest_now()
        for key, name in gp_test.OUTPUTS.items():
            self.assertEqual(manifest["outputs"][key], name)
        tests = pd.read_csv(self.directory / "cluster_gp_tests.tsv", sep="\t")
        self.assertEqual(list(tests.columns), ["cluster", "n_genes", "log_bf", "permutations", "exact", "p_value",
                                               "q_value", "significant", "diverges_at", "pre_treatment_gap"])
        self.assertEqual(list(tests["permutations"]), [20, 20, 20])
        self.assertTrue(tests["exact"].all())
        # Only 20 ways to relabel the 24 h samples: p cannot go below 0.05.
        self.assertTrue((tests["p_value"] >= 0.05 - 1e-12).all())
        self.assertEqual(tests["p_value"][0], 0.05)
        self.assertGreater(tests["p_value"][1], 0.05)
        self.assertTrue((tests["q_value"] >= tests["p_value"] - 1e-12).all())
        self.assertFalse(tests["significant"].any())
        test = manifest["gaussian_process"]["test"]
        self.assertEqual((test["treatment_timing"], test["treatment_start"], test["min_possible_p"]), ("added", 6.0, 0.05))
        self.assertEqual(len(test["warnings"]), 1)
        self.assertIn("smallest possible p-value is 0.05", test["warnings"][0])
        self.assertEqual(manifest["gaussian_process"]["conditions"], ["control", "treated"])
        curves = pd.read_csv(self.directory / "cluster_gp_curves.tsv", sep="\t")
        self.assertEqual(sorted(curves["condition"].unique()), ["control", "treated"])
        fits = pd.read_csv(self.directory / "cluster_gp_fits.tsv", sep="\t", keep_default_na=False, na_values=["NA"])
        self.assertEqual(len(fits), 6)
        differences = pd.read_csv(self.directory / "cluster_gp_differences.tsv", sep="\t")
        np.testing.assert_allclose(differences.loc[differences["time"] <= 6, "difference"], 0.0, atol=1e-10)

    def test_from_the_start_is_the_default(self):
        result = self.run_script("--permutations", "99")
        self.assertEqual(result.returncode, 0, result.stderr)
        tests = pd.read_csv(self.directory / "cluster_gp_tests.tsv", sep="\t")
        self.assertNotIn("pre_treatment_gap", tests.columns)
        self.assertEqual(list(tests["permutations"]), [99, 99, 99])
        test = self.manifest_now()["gaussian_process"]["test"]
        self.assertEqual((test["treatment_timing"], test["treatment_start"], test["exact"]), ("from_start", None, False))
        self.assertEqual(list(tests["significant"]), [True, False, True])

    def test_a_treatment_time_at_the_end_is_skipped_with_a_reason(self):
        result = self.run_script("--treatment-start", "24")
        self.assertEqual(result.returncode, 0, result.stderr)
        gp = self.manifest_now()["gaussian_process"]
        self.assertEqual(gp["status"], "skipped")
        self.assertIn("before the last", gp["reason"])
        self.assertFalse((self.directory / "cluster_gp_tests.tsv").exists())

    def test_bad_permutation_counts_and_other_analyses_are_refused(self):
        for value in ("10", "10000"):
            result = self.run_script("--permutations", value)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("from 99 to 9999", result.stderr)
        (self.directory / "manifest.json").write_text(json.dumps({**self.manifest, "experiment_type": "condition_by_time"}))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("applies only to a Gaussian process comparison", result.stderr)


if __name__ == "__main__":
    unittest.main()
