"""Scientific-correctness tests for lib/scripts/rnaseq/deseq2_analysis.R.

A. Agreement with independent references: a numpy median-of-ratios
   implementation and a plain DESeq2 script that shares no code with ours.
B. Recovery of known truth from simulated negative-binomial counts.
C. Invariants the statistics must satisfy: sample/gene order, reference
   swap, and selecting significant genes only after the VST.
D. Input validation.

Requires Rscript with DESeq2 and jsonlite, as installed in the MicroNet image.
"""
import dataclasses
import importlib.util
import itertools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "lib/scripts/rnaseq/deseq2_analysis.R"
REFERENCE = ROOT / "test/scripts/fixtures/rnaseq_reference_deseq2.R"
RSCRIPT = os.environ.get("RSCRIPT_EXECUTABLE") or shutil.which("Rscript")
NO_R = "Rscript is not installed; run these tests inside the MicroNet Docker image."

spec = importlib.util.spec_from_file_location("rnaseq_simulation", ROOT / "test/scripts/rnaseq_simulation.py")
simulation = importlib.util.module_from_spec(spec)
sys.modules["rnaseq_simulation"] = simulation
spec.loader.exec_module(simulation)

BASE_CONFIG = {"schema_version": 1, "experiment_type": "two_condition",
               "reference_level": "control", "test_level": "treated"}
RESULT_COLUMNS = ["baseMean", "log2FoldChange", "lfcSE", "stat", "pvalue", "padj"]
RUN_NUMBERS = itertools.count()
WORK = None


def setUpModule():
    global WORK
    WORK = tempfile.TemporaryDirectory(prefix="micronet-deseq2-")


def tearDownModule():
    WORK.cleanup()


def read_table(path):
    frame = pd.read_csv(path, sep="\t")
    frame = frame.set_index(frame.columns[0])
    frame.index = frame.index.astype(str)
    return frame


class Run:
    def __init__(self, out, inputs, completed):
        self.out = Path(out)
        self.counts_path, self.metadata_path = inputs
        self.returncode = completed.returncode
        self.stderr = completed.stderr
        self.manifest = json.loads((self.out / "manifest.json").read_text())

    def table(self, name):
        return read_table(self.out / name)

    @property
    def results(self):
        results = self.table("deseq2_results.tsv")
        results["padj_na_reason"] = results["padj_na_reason"].fillna("")
        return results

    @property
    def size_factors(self):
        return self.table("size_factors.tsv")["size_factor"]

    @property
    def significant_genes(self):
        results = self.results
        return results.index[results["significant"]]


def analyze(experiment, overrides=None, config=None, counts_name="counts.tsv", out=None):
    directory = Path(WORK.name) / f"run{next(RUN_NUMBERS)}"
    inputs = simulation.write_inputs(experiment, directory / "input", counts_name=counts_name)
    config_path = directory / "config.json"
    config_path.write_text(json.dumps(config if config is not None else {**BASE_CONFIG, **(overrides or {})}))
    out = Path(out) if out else directory / "out"
    completed = subprocess.run(
        [RSCRIPT, str(SCRIPT), "--counts", str(inputs[0]), "--metadata", str(inputs[1]),
         "--config", str(config_path), "--out", str(out)],
        capture_output=True, text=True, timeout=900,
    )
    return Run(out, inputs, completed)


def analyze_successfully(*args, **kwargs):
    run = analyze(*args, **kwargs)
    if run.returncode != 0:
        raise AssertionError(f"analysis failed: {run.manifest.get('message')}\n{run.stderr}")
    return run


def set_first_count(value):
    def change(counts):
        counts.iat[0, 0] = value
    return change


def run_reference(run, genes=None):
    out = run.out.parent / "reference"
    arguments = [RSCRIPT, str(REFERENCE), str(run.counts_path), str(run.metadata_path), "control", "treated", str(out)]
    if genes is not None:
        genes_path = run.out.parent / "genes.txt"
        genes_path.write_text("\n".join(genes) + "\n")
        arguments.append(str(genes_path))
    subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=900)
    return out


def assert_close(actual, expected, rtol=1e-8, atol=1e-10):
    assert sorted(actual.index) == sorted(expected.index), "gene or sample sets differ"
    expected = expected.loc[actual.index]
    np.testing.assert_allclose(actual.to_numpy(float), expected.to_numpy(float), rtol=rtol, atol=atol, equal_nan=True)


def median_of_ratios(counts):
    """Independent implementation of DESeq2's size factor estimator."""
    with np.errstate(divide="ignore"):
        logs = np.log(counts.to_numpy(dtype=float))
    log_geometric_means = logs.mean(axis=1)
    usable = np.isfinite(log_geometric_means)
    factors = np.exp(np.median(logs[usable] - log_geometric_means[usable, None], axis=0))
    return pd.Series(factors, index=counts.columns)


def geometric_mean_one(values):
    return values / np.exp(np.mean(np.log(values)))


def prefiltered(experiment, min_count=10):
    smallest_group = experiment.metadata["condition"].value_counts().min()
    return experiment.counts[(experiment.counts >= min_count).sum(axis=1) >= smallest_group]


@unittest.skipUnless(RSCRIPT, NO_R)
class ReferenceAgreementTest(unittest.TestCase):
    """A + C: our wrapper must reproduce independent computations exactly."""

    @classmethod
    def setUpClass(cls):
        cls.experiment = simulation.simulate(seed=11)
        cls.analysis = analyze_successfully(cls.experiment)
        cls.reference = run_reference(cls.analysis, genes=list(cls.analysis.significant_genes))

    def test_size_factors_match_an_independent_median_of_ratios(self):
        expected = median_of_ratios(prefiltered(self.experiment))
        assert_close(geometric_mean_one(self.analysis.size_factors), geometric_mean_one(expected), rtol=1e-6)

    def test_normalized_counts_are_raw_counts_divided_by_size_factors(self):
        normalized = self.analysis.table("normalized_counts.tsv")
        raw = self.experiment.counts.loc[normalized.index, normalized.columns]
        assert_close(normalized, raw / self.analysis.size_factors[normalized.columns], rtol=1e-9)

    def test_results_match_plain_deseq2(self):
        expected = read_table(self.reference / "results.tsv")
        assert_close(self.analysis.results[RESULT_COLUMNS], expected[RESULT_COLUMNS])

    def test_size_factors_and_vst_match_plain_deseq2(self):
        assert_close(self.analysis.size_factors, read_table(self.reference / "size_factors.tsv")["size_factor"])
        assert_close(self.analysis.table("vst_all.tsv"), read_table(self.reference / "vst_all.tsv"))

    def test_every_output_covers_exactly_the_prefiltered_genes(self):
        expected = sorted(prefiltered(self.experiment).index)
        for name in ["deseq2_results.tsv", "normalized_counts.tsv", "vst_all.tsv"]:
            self.assertEqual(sorted(self.analysis.table(name).index), expected, name)

    def test_vst_significant_is_the_significant_rows_of_vst_all(self):
        vst_all = self.analysis.table("vst_all.tsv")
        vst_significant = self.analysis.table("vst_significant.tsv")
        self.assertGreater(len(vst_significant), 0)
        self.assertEqual(sorted(vst_significant.index), sorted(self.analysis.significant_genes))
        pd.testing.assert_frame_equal(vst_significant, vst_all.loc[vst_significant.index])

    def test_transforming_after_selection_would_give_different_values(self):
        # Counter-test: if the pipeline selected genes before normalizing and
        # transforming, its output would look like vst_subset_first.tsv.
        subset_first = read_table(self.reference / "vst_subset_first.tsv")
        correct = self.analysis.table("vst_significant.tsv").loc[subset_first.index]
        self.assertGreater(np.abs(subset_first.to_numpy() - correct.to_numpy()).max(), 0.05)

    def test_manifest_counts_agree_with_the_tables(self):
        results = self.analysis.results
        genes = self.analysis.manifest["genes"]
        self.assertEqual(self.analysis.manifest["status"], "completed")
        self.assertEqual(genes["in_input"], len(self.experiment.counts))
        self.assertEqual(genes["passed_prefilter"], len(results))
        self.assertEqual(genes["significant"], int(results["significant"].sum()))
        self.assertEqual(genes["significant_up"] + genes["significant_down"], genes["significant"])
        self.assertEqual(self.analysis.manifest["vst_method"], "vst")
        self.assertEqual(self.analysis.manifest["contrast"]["log2_fold_change"], "log2(treated / control)")


@unittest.skipUnless(RSCRIPT, NO_R)
class TruthRecoveryTest(unittest.TestCase):
    """B: simulated data with known size factors and fold changes."""

    SEEDS = [21, 22, 23]

    @classmethod
    def setUpClass(cls):
        cls.experiments = [simulation.simulate(seed=seed) for seed in cls.SEEDS]
        cls.runs = [analyze_successfully(experiment) for experiment in cls.experiments]

    def joined(self, index):
        results = self.runs[index].results
        return results.join(self.experiments[index].truth, how="inner")

    def test_size_factors_recover_true_library_depths(self):
        for experiment, run in zip(self.experiments, self.runs):
            estimated = np.log(geometric_mean_one(run.size_factors))
            true = np.log(experiment.size_factors.loc[estimated.index])
            self.assertGreater(np.corrcoef(estimated, true)[0, 1], 0.99)
            self.assertLess(np.abs(estimated - true).max(), 0.1)

    def test_strong_effects_are_detected(self):
        for index in range(len(self.runs)):
            table = self.joined(index)
            strong = table[table["is_de"] & (table["true_lfc"].abs() >= 2) & (table["base_mean"] >= 50)]
            self.assertGreater(len(strong), 20)
            self.assertGreaterEqual(strong["significant"].mean(), 0.9)

    def test_false_discovery_rate_is_controlled(self):
        called = pd.concat([self.joined(index) for index in range(len(self.runs))])
        called = called[called["significant"]]
        self.assertLessEqual((~called["is_de"]).mean(), 0.10)

    def test_called_true_effects_have_the_correct_direction(self):
        for index in range(len(self.runs)):
            table = self.joined(index)
            hits = table[table["significant"] & table["is_de"]]
            self.assertTrue((np.sign(hits["log2FoldChange"]) == np.sign(hits["true_lfc"])).all())

    def test_fold_changes_are_estimated_accurately(self):
        for index in range(len(self.runs)):
            table = self.joined(index)
            expressed = table[table["is_de"] & (table["base_mean"] >= 50)]
            self.assertLess((expressed["log2FoldChange"] - expressed["true_lfc"]).abs().median(), 0.25)

    def test_null_genes_have_a_nominal_false_positive_rate(self):
        nulls = pd.concat([self.joined(index) for index in range(len(self.runs))])
        nulls = nulls[~nulls["is_de"] & nulls["pvalue"].notna()]
        self.assertTrue(0.01 <= (nulls["pvalue"] < 0.05).mean() <= 0.09)


@unittest.skipUnless(RSCRIPT, NO_R)
class InvarianceTest(unittest.TestCase):
    """C: properties that must hold whatever the input layout or thresholds."""

    @classmethod
    def setUpClass(cls):
        cls.experiment = simulation.simulate(seed=31)
        cls.base = analyze_successfully(cls.experiment)

    def test_sample_and_gene_order_do_not_change_results(self):
        rng = np.random.default_rng(0)
        counts = self.experiment.counts
        shuffled = dataclasses.replace(
            self.experiment,
            counts=counts.iloc[rng.permutation(len(counts)), rng.permutation(counts.shape[1])],
            metadata=self.experiment.metadata.iloc[rng.permutation(len(self.experiment.metadata))],
        )
        run = analyze_successfully(shuffled)
        assert_close(run.results[RESULT_COLUMNS], self.base.results[RESULT_COLUMNS], rtol=1e-6, atol=1e-9)
        self.assertEqual(sorted(run.significant_genes), sorted(self.base.significant_genes))

    def test_swapping_the_reference_negates_fold_changes_only(self):
        run = analyze_successfully(self.experiment, {"reference_level": "treated", "test_level": "control"})
        swapped, base = run.results, self.base.results.loc[run.results.index]
        # Swapping the reference reparameterizes the GLM, whose iterative fit
        # stops at DESeq2's convergence tolerance; the two fits differ by up to
        # ~6e-6 (measured, seed 31), so exact negation is not expected.
        tolerance = {"atol": 1e-5, "rtol": 0, "equal_nan": True}
        np.testing.assert_allclose(swapped["log2FoldChange"], -base["log2FoldChange"], **tolerance)
        np.testing.assert_allclose(swapped["stat"], -base["stat"], **tolerance)
        for column in ["lfcSE", "pvalue", "padj"]:
            np.testing.assert_allclose(swapped[column], base[column], **tolerance)
        pd.testing.assert_series_equal(swapped["significant"], base["significant"])

    def test_thresholds_change_only_the_selection(self):
        run = analyze_successfully(self.experiment, {"alpha": 0.1, "lfc_threshold": 1, "lfc_test": "posthoc"})
        pd.testing.assert_series_equal(run.size_factors, self.base.size_factors)
        pd.testing.assert_frame_equal(run.table("vst_all.tsv"), self.base.table("vst_all.tsv"))
        results = run.results
        expected = results["padj"].lt(0.1) & results["log2FoldChange"].abs().ge(1)
        pd.testing.assert_series_equal(results["significant"], expected, check_names=False)

    def test_deseq2_threshold_test_calls_only_large_effects(self):
        run = analyze_successfully(self.experiment, {"lfc_threshold": 1, "lfc_test": "deseq2"})
        results = run.results
        self.assertGreater(results["significant"].sum(), 0)
        self.assertTrue((results.loc[results["significant"], "log2FoldChange"].abs() > 1).all())

    def test_csv_input_matches_tsv_input(self):
        run = analyze_successfully(self.experiment, counts_name="counts.csv")
        assert_close(run.results[RESULT_COLUMNS], self.base.results[RESULT_COLUMNS])


@unittest.skipUnless(RSCRIPT, NO_R)
class DesignOptionsTest(unittest.TestCase):
    def test_contrast_only_excludes_other_conditions(self):
        experiment = simulation.simulate(seed=61, replicates=(3, 3, 3), levels=("control", "treated", "other"))
        everything = analyze_successfully(experiment)
        contrast_only = analyze_successfully(experiment, {"samples_in_model": "contrast_only"})
        self.assertEqual(everything.manifest["samples"]["in_model"], 9)
        self.assertEqual(contrast_only.manifest["samples"]["in_model"], 6)
        self.assertFalse(any(sample.startswith("other") for sample in contrast_only.size_factors.index))

    def test_batch_covariate_is_modeled(self):
        experiment = simulation.simulate(seed=62, batch=True)
        run = analyze_successfully(experiment, {"covariates": ["batch"]})
        self.assertEqual(run.manifest["design"], "~ batch + condition")
        self.assertEqual(run.manifest["parameters"]["covariates"], ["batch"])

    def test_small_datasets_use_the_exact_transformation(self):
        run = analyze_successfully(simulation.simulate(seed=63, n_genes=300))
        self.assertEqual(run.manifest["vst_method"], "varianceStabilizingTransformation")

    def test_missing_adjusted_p_values_are_explained(self):
        experiment = simulation.simulate(seed=64, n_genes=1500, replicates=(3, 3))
        counts = experiment.counts.copy()
        counts.loc["gene00001"] = [500, 520, 480, 510, 490, 50000]
        run = analyze_successfully(dataclasses.replace(experiment, counts=counts))
        results = run.results
        self.assertEqual(results.loc["gene00001", "padj_na_reason"], "cooks_outlier")
        self.assertFalse(results.loc["gene00001", "significant"])
        missing = results["padj"].isna()
        self.assertTrue(results.loc[missing, "padj_na_reason"].isin(["cooks_outlier", "independent_filtering"]).all())
        self.assertTrue((results.loc[~missing, "padj_na_reason"] == "").all())
        self.assertFalse(results.loc[missing, "significant"].any())


@unittest.skipUnless(RSCRIPT, NO_R)
class InputValidationTest(unittest.TestCase):
    """D: bad inputs fail with an actionable message and no result files."""

    def setUp(self):
        self.experiment = simulation.simulate(seed=51, n_genes=60, replicates=(3, 3))

    def with_counts(self, change, dtype=None):
        counts = self.experiment.counts.astype(dtype) if dtype else self.experiment.counts.copy()
        change(counts)
        return dataclasses.replace(self.experiment, counts=counts)

    def with_metadata(self, change):
        metadata = self.experiment.metadata.copy()
        change(metadata)
        return dataclasses.replace(self.experiment, metadata=metadata)

    def assert_input_error(self, run, fragment):
        self.assertEqual(run.returncode, 1)
        self.assertEqual(run.manifest["status"], "failed")
        self.assertEqual(run.manifest["error_type"], "input_error", run.manifest["message"])
        self.assertIn(fragment, run.manifest["message"])
        self.assertFalse((run.out / "deseq2_results.tsv").exists())

    def test_fractional_counts(self):
        run = analyze(self.with_counts(set_first_count(12.5), float))
        self.assert_input_error(run, "whole numbers")

    def test_negative_counts(self):
        self.assert_input_error(analyze(self.with_counts(set_first_count(-1))), "negative")

    def test_missing_counts(self):
        run = analyze(self.with_counts(set_first_count(np.nan), float))
        self.assert_input_error(run, "missing values")

    def test_non_numeric_counts(self):
        run = analyze(self.with_counts(set_first_count("abc"), object))
        self.assert_input_error(run, "not a number")

    def test_duplicate_gene_ids(self):
        def duplicate(counts):
            counts.index = [counts.index[0]] + list(counts.index[:-1])
        self.assert_input_error(analyze(self.with_counts(duplicate)), "Duplicate gene IDs")

    def test_samples_that_do_not_match(self):
        def rename(metadata):
            metadata["sample"] = metadata["sample"].replace({"treated_3": "treated_x"})
        run = analyze(self.with_metadata(rename))
        self.assert_input_error(run, "must match exactly")
        self.assertIn("treated_3", run.manifest["message"])
        self.assertIn("treated_x", run.manifest["message"])

    def test_too_few_replicates(self):
        run = analyze(simulation.simulate(seed=52, n_genes=60, replicates=(1, 3)))
        self.assert_input_error(run, "biological replicates")

    def test_identical_reference_and_test(self):
        self.assert_input_error(analyze(self.experiment, {"test_level": "control"}), "must be different")

    def test_absent_condition_level(self):
        self.assert_input_error(analyze(self.experiment, {"test_level": "drug"}), "not found in column")

    def test_unsupported_experiment_type(self):
        self.assert_input_error(analyze(self.experiment, {"experiment_type": "multi_condition"}), "not supported yet")

    def test_unknown_setting(self):
        self.assert_input_error(analyze(self.experiment, {"alhpa": 0.05}), "Unknown configuration")

    def test_confounded_covariate(self):
        def confound(metadata):
            metadata["batch"] = metadata["condition"]
        experiment = self.with_metadata(confound)
        self.assert_input_error(analyze(experiment, {"covariates": ["batch"]}), "confounded")

    def test_sample_without_counts(self):
        def empty_first_sample(counts):
            counts.iloc[:, 0] = 0
        self.assert_input_error(analyze(self.with_counts(empty_first_sample)), "no counts")

    def test_failure_removes_results_from_an_earlier_run(self):
        first = analyze_successfully(self.experiment)
        self.assertTrue((first.out / "deseq2_results.tsv").exists())
        second = analyze(self.experiment, {"test_level": "drug"}, out=first.out)
        self.assert_input_error(second, "not found in column")



# ---- Time-course designs ---------------------------------------------------

LRT_REFERENCE = ROOT / "test/scripts/fixtures/rnaseq_reference_lrt.R"
TIME_COURSE = {"schema_version": 1, "experiment_type": "time_course", "subset_level": "control"}
CONDITION_BY_TIME = {"schema_version": 1, "experiment_type": "condition_by_time",
                     "reference_level": "control", "test_level": "treated"}


def run_lrt_reference(run, *arguments):
    out = run.out.parent / "lrt_reference"
    subprocess.run([RSCRIPT, str(LRT_REFERENCE), *arguments[:1], str(run.counts_path), str(run.metadata_path),
                    str(out), *arguments[1:]], check=True, capture_output=True, text=True, timeout=900)
    return read_table(out / "results.tsv")


def effect_columns(results):
    return [column for column in results.columns if column.startswith("log2FC_")]


@unittest.skipUnless(RSCRIPT, NO_R)
class TimeCourseReferenceTest(unittest.TestCase):
    """A: the time-course designs agree with textbook DESeq2 likelihood ratio tests."""

    @classmethod
    def setUpClass(cls):
        cls.experiment = simulation.simulate_time_course(seed=61)
        cls.time_course = analyze_successfully(cls.experiment, config=TIME_COURSE)
        cls.interaction = analyze_successfully(cls.experiment, config=CONDITION_BY_TIME)

    def test_time_course_matches_plain_deseq2(self):
        reference = run_lrt_reference(self.time_course, "time_course", "control")
        results = self.time_course.results
        columns = ["baseMean", "stat", "pvalue", "padj", *effect_columns(reference)]
        self.assertEqual(effect_columns(results), ["log2FC_time_6_vs_0", "log2FC_time_24_vs_0"])
        assert_close(results[columns], reference[columns], rtol=1e-6, atol=1e-8)

    def test_condition_by_time_matches_plain_deseq2(self):
        reference = run_lrt_reference(self.interaction, "condition_by_time", "control", "treated")
        results = self.interaction.results
        columns = ["baseMean", "stat", "pvalue", "padj", *effect_columns(reference)]
        self.assertEqual(effect_columns(results), [f"log2FC_treated_vs_control_at_time_{time}" for time in (0, 6, 24)])
        assert_close(results[columns], reference[columns], rtol=1e-6, atol=1e-8)

    def test_only_the_chosen_samples_are_modeled(self):
        manifest = self.time_course.manifest
        self.assertEqual(manifest["samples"]["in_model"], 9)
        self.assertEqual(manifest["samples"]["per_group"], {"time 0": 3, "time 6": 3, "time 24": 3})
        self.assertTrue(all(sample.startswith("control_") for sample in self.time_course.size_factors.index))
        self.assertEqual(self.interaction.manifest["samples"]["in_model"], 18)

    def test_times_are_ordered_numerically_and_recorded(self):
        time = self.interaction.manifest["time"]
        self.assertEqual(time, {"column": "time", "levels": ["0", "6", "24"], "numeric_values": [0, 6, 24], "baseline": "0"})
        self.assertEqual(self.interaction.manifest["test"], "likelihood_ratio")
        self.assertIsNone(self.interaction.manifest["genes"]["significant_up"])

    def test_group_means_are_the_mean_vst_of_each_group(self):
        for run in (self.time_course, self.interaction):
            vst = run.table("vst_all.tsv")
            samples = run.table("size_factors.tsv")
            means = pd.read_csv(run.out / "group_means_vst.tsv", sep="\t", keep_default_na=False, na_values=["NA"])
            means["gene_id"] = means["gene_id"].astype(str)
            self.assertEqual(len(means), len(vst) * len(run.manifest["samples"]["per_group"]))
            for (condition, time), group in means.groupby(["condition", "time"]):
                members = samples.index[(samples["time"] == time) &
                                        ((samples["condition"] == condition) if condition else True)]
                expected = vst[members].mean(axis=1)
                np.testing.assert_allclose(group.set_index("gene_id").loc[vst.index, "mean_vst"], expected, rtol=1e-10)
                self.assertTrue((group["n_samples"] == len(members)).all())
                self.assertTrue((group["time_value"] == float(time)).all())

    def test_vst_significant_is_the_significant_rows_of_vst_all(self):
        run = self.interaction
        vst_all = run.table("vst_all.tsv")
        vst_significant = run.table("vst_significant.tsv")
        self.assertEqual(list(vst_significant.index), [gene for gene in vst_all.index if gene in set(run.significant_genes)])
        assert_close(vst_significant, vst_all.loc[vst_significant.index])


@unittest.skipUnless(RSCRIPT, NO_R)
class TimeCourseTruthRecoveryTest(unittest.TestCase):
    """B: simulated time-varying and interaction genes are found; others mostly are not."""
    SEEDS = (71, 72)

    @classmethod
    def setUpClass(cls):
        cls.runs = []
        for seed in cls.SEEDS:
            experiment = simulation.simulate_time_course(seed=seed)
            cls.runs.append((experiment.truth,
                             analyze_successfully(experiment, config=TIME_COURSE).results,
                             analyze_successfully(experiment, config=CONDITION_BY_TIME).results))

    def rates(self, results, truth, true_kinds):
        truth = truth.loc[results.index]
        called = results["significant"].to_numpy()
        positive = truth["kind"].isin(true_kinds).to_numpy()
        return (called & positive).sum() / positive.sum(), (called & ~positive).sum() / max(called.sum(), 1)

    def test_genes_that_change_over_time_are_found(self):
        recalls, fdrs = zip(*(self.rates(time_course, truth, ["time"]) for truth, time_course, _ in self.runs))
        self.assertGreaterEqual(min(recalls), 0.8)
        # Three replicates per time point make dispersion estimates noisy, so
        # allow some excess over the nominal 5%.
        self.assertLessEqual(np.mean(fdrs), 0.12)

    def test_condition_specific_time_changes_are_found(self):
        recalls, fdrs = zip(*(self.rates(interaction, truth, ["interaction"]) for truth, _, interaction in self.runs))
        self.assertGreaterEqual(min(recalls), 0.75)
        self.assertLessEqual(np.mean(fdrs), 0.12)

    def test_constant_differences_and_shared_trends_are_not_interactions(self):
        for truth, _, interaction in self.runs:
            kinds = truth.loc[interaction.index, "kind"]
            for kind in ("condition", "time"):
                called = interaction.loc[kinds == kind, "significant"].mean()
                self.assertLessEqual(called, 0.05, kind)

    def test_per_time_fold_changes_estimate_the_truth(self):
        for truth, time_course, interaction in self.runs:
            changing = truth.loc[time_course.index, "kind"].eq("time")
            np.testing.assert_array_less(0.95, np.corrcoef(time_course.loc[changing, "log2FC_time_24_vs_0"],
                                                             truth.loc[time_course.index[changing], "reference_lfc_at_24"])[0, 1])
            responding = truth.loc[interaction.index, "kind"].eq("interaction")
            np.testing.assert_array_less(0.95, np.corrcoef(interaction.loc[responding, "log2FC_treated_vs_control_at_time_24"],
                                                             truth.loc[interaction.index[responding], "test_vs_reference_lfc_at_24"])[0, 1])

    def test_posthoc_cutoff_uses_the_largest_change(self):
        experiment = simulation.simulate_time_course(seed=self.SEEDS[0])
        strict = analyze_successfully(experiment, config={**TIME_COURSE, "lfc_threshold": 1.5}).results
        loose = self.runs[0][1]
        self.assertTrue(set(strict.index[strict["significant"]]) <= set(loose.index[loose["significant"]]))
        self.assertTrue((strict.loc[strict["significant"], "max_abs_log2FC"] >= 1.5).all())
        expected = loose[effect_columns(loose)].abs().max(axis=1)
        np.testing.assert_allclose(loose["max_abs_log2FC"], expected)


@unittest.skipUnless(RSCRIPT, NO_R)
class TimeCourseValidationTest(unittest.TestCase):
    """D: time-course inputs that cannot be analyzed fail with a clear message."""

    def setUp(self):
        self.experiment = simulation.simulate_time_course(seed=81, n_genes=80, replicates=2)

    def with_metadata(self, change):
        metadata = self.experiment.metadata.copy()
        change(metadata)
        return dataclasses.replace(self.experiment, metadata=metadata)

    def assert_input_error(self, run, fragment):
        self.assertEqual(run.returncode, 1, run.manifest)
        self.assertEqual(run.manifest["error_type"], "input_error", run.manifest["message"])
        self.assertIn(fragment, run.manifest["message"])
        self.assertFalse((run.out / "deseq2_results.tsv").exists())

    def test_a_single_time_point(self):
        def one_time(metadata):
            metadata["time"] = 0
        self.assert_input_error(analyze(self.with_metadata(one_time), config=TIME_COURSE), "at least two different time points")

    def test_a_time_point_with_one_replicate(self):
        def thin(metadata):
            metadata.loc[metadata["sample"] == "control_t6_2", "time"] = 99
        self.assert_input_error(analyze(self.with_metadata(thin), config=TIME_COURSE), "time 99 (1)")

    def test_a_condition_missing_a_time_point(self):
        def drop(metadata):
            metadata.loc[metadata["sample"].str.startswith("treated_t24"), "condition"] = "other"
        self.assert_input_error(analyze(self.with_metadata(drop), config=CONDITION_BY_TIME), "treated @ time 24")

    def test_the_same_time_written_twice(self):
        def respell(metadata):
            metadata["time"] = metadata["time"].astype(str)
            metadata.loc[metadata["sample"] == "control_t0_1", "time"] = "0.0"
        self.assert_input_error(analyze(self.with_metadata(respell), config=TIME_COURSE), "same time in different ways")

    def test_time_column_cannot_be_the_condition_column(self):
        config = {**CONDITION_BY_TIME, "time_column": "condition"}
        self.assert_input_error(analyze(self.experiment, config=config), "time column must be different")

    def test_cutoff_cannot_be_tested_by_deseq2(self):
        config = {**TIME_COURSE, "lfc_threshold": 1, "lfc_test": "deseq2"}
        self.assert_input_error(analyze(self.experiment, config=config), "only be applied after testing")

    def test_missing_time_column(self):
        config = {**TIME_COURSE, "time_column": "hours"}
        self.assert_input_error(analyze(self.experiment, config=config), "The time column 'hours' was not found")

    def test_unknown_subset_level(self):
        config = {**TIME_COURSE, "subset_level": "mutant"}
        self.assert_input_error(analyze(self.experiment, config=config), "'mutant' was not found")

    def test_text_time_points_keep_their_order(self):
        def label(metadata):
            metadata["time"] = metadata["time"].map({0: "early", 6: "middle", 24: "late"})
        run = analyze_successfully(self.with_metadata(label), config=TIME_COURSE)
        self.assertEqual(run.manifest["time"]["levels"], ["early", "middle", "late"])
        self.assertIsNone(run.manifest["time"]["numeric_values"])


if __name__ == "__main__":
    unittest.main()
