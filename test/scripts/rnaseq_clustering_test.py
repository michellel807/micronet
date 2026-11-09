"""Tests for lib/scripts/rnaseq/cluster_genes.py on synthetic gene patterns.

These need only NumPy, SciPy and pandas, not R: the group means are built
directly, with planted pattern groups whose true membership is known.
"""
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from itertools import combinations
from math import comb
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.spatial.distance import cdist

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "lib/scripts/rnaseq/cluster_genes.py"
spec = importlib.util.spec_from_file_location("cluster_genes", SCRIPT)
cluster_genes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cluster_genes)

TIMES = ["0", "2", "6", "12", "24", "48"]
SHAPES = {
    "rise": [0, 1, 2, 3, 4, 5],
    "fall": [5, 4, 3, 2, 1, 0],
    "peak": [0, 3, 5, 5, 3, 0],
    "dip": [5, 2, 0, 0, 2, 5],
}


def adjusted_rand(truth, labels):
    table = pd.crosstab(np.asarray(truth), np.asarray(labels)).to_numpy()
    pairs = sum(comb(int(count), 2) for count in table.flat)
    rows = sum(comb(int(count), 2) for count in table.sum(axis=1))
    columns = sum(comb(int(count), 2) for count in table.sum(axis=0))
    expected = rows * columns / comb(int(table.sum()), 2)
    return (pairs - expected) / ((rows + columns) / 2 - expected)


def planted(per_shape=60, noise=0.4, seed=3, shapes=SHAPES, conditions=("",)):
    """Long-format group means: each gene follows one shape, scaled and shifted, plus noise."""
    rng = np.random.default_rng(seed)
    rows, truth = [], {}
    for name, shape in shapes.items():
        for index in range(per_shape):
            gene = f"{name}_{index:03d}"
            truth[gene] = name
            level, scale = rng.uniform(4, 12), rng.uniform(0.3, 1.5)
            for condition in conditions:
                for time, value in zip(TIMES, shape):
                    rows.append({"gene_id": gene, "condition": condition, "time": time, "time_value": float(time),
                                 "n_samples": 3, "mean_vst": level + scale * value + rng.normal(0, noise * scale)})
    return pd.DataFrame(rows), truth


class ClusteringMethodTest(unittest.TestCase):
    def test_automatic_choice_finds_the_planted_patterns(self):
        means, truth = planted()
        result = cluster_genes.cluster(means, list(truth), TIMES)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["chosen"], 4)
        self.assertGreaterEqual(adjusted_rand([truth[gene] for gene in result["genes"]], result["labels"]), 0.9)
        selection = result["selection"]
        self.assertEqual(selection.loc[selection["chosen"], "k"].tolist(), [4])
        self.assertEqual(selection["k"].tolist(), list(range(2, 11)))

    def test_expression_level_does_not_decide_the_cluster(self):
        means, truth = planted(noise=0.1)
        # Make half of every pattern's genes 100 times more highly expressed.
        high = means["gene_id"].str.endswith(("0", "2", "4", "6", "8"))
        means.loc[high, "mean_vst"] += np.log2(100)
        result = cluster_genes.cluster(means, list(truth), TIMES, requested=4)
        self.assertEqual(adjusted_rand([truth[gene] for gene in result["genes"]], result["labels"]), 1.0)

    def test_the_same_input_gives_the_same_clusters(self):
        means, truth = planted(noise=1.0)
        first = cluster_genes.cluster(means, list(truth), TIMES)
        second = cluster_genes.cluster(means, list(truth), TIMES)
        np.testing.assert_array_equal(first["labels"], second["labels"])
        pd.testing.assert_frame_equal(first["selection"], second["selection"])

    def test_a_chosen_number_is_used_and_every_number_is_still_scored(self):
        means, truth = planted()
        result = cluster_genes.cluster(means, list(truth), TIMES, requested=6)
        self.assertEqual(result["chosen"], 6)
        self.assertEqual(len(set(result["labels"])), 6)
        self.assertEqual(result["selection"].loc[result["selection"]["chosen"], "k"].tolist(), [6])
        self.assertEqual(len(result["selection"]), 9)

    def test_clusters_are_numbered_largest_first(self):
        sizes = {"rise": 80, "fall": 20, "peak": 50, "dip": 35}
        frames, truth = [], {}
        for name, size in sizes.items():
            frame, shape_truth = planted(per_shape=size, shapes={name: SHAPES[name]}, seed=len(name) + size)
            frames.append(frame)
            truth.update(shape_truth)
        result = cluster_genes.cluster(pd.concat(frames), list(truth), TIMES, requested=4)
        counts = np.bincount(result["labels"])[1:]
        self.assertEqual(counts.tolist(), [80, 50, 35, 20])
        self.assertEqual(cluster_genes.summary(result)["cluster_sizes"], [80, 50, 35, 20])

    def test_silhouette_matches_its_definition(self):
        rng = np.random.default_rng(5)
        data = np.vstack([rng.normal(center, 0.5, size=(7, 3)) for center in (0, 3, 6)])
        labels = np.repeat([0, 1, 2], 7)
        labels[[0, 8]] = [1, 2]  # some misassigned points
        labels[20] = 3  # a cluster of one point scores 0
        distance = cdist(data, data)
        scores = []
        for point in range(len(data)):
            own = labels == labels[point]
            if own.sum() == 1:
                scores.append(0.0)
                continue
            a = distance[point, own].sum() / (own.sum() - 1)
            b = min(distance[point, labels == other].mean() for other in set(labels) - {labels[point]})
            scores.append((b - a) / max(a, b))
        self.assertAlmostEqual(cluster_genes.silhouette(data, labels), float(np.mean(scores)), places=12)

    def test_kmeans_finds_the_lowest_spread_split(self):
        # Two tight groups of three points: the best split is obvious, and the
        # spread must equal the brute-force minimum over all splits.
        data = np.array([[0, 0], [0, 1], [1, 0], [10, 10], [10, 11], [11, 10]], dtype=float)
        labels, _, spread = cluster_genes.kmeans_best(data, 2)
        best = min(
            sum(((data[list(group)] - data[list(group)].mean(axis=0)) ** 2).sum()
                for group in (chosen, tuple(set(range(6)) - set(chosen))))
            for size in range(1, 6) for chosen in combinations(range(6), size)
        )
        self.assertAlmostEqual(spread, best)
        self.assertEqual(len(set(labels[:3])), 1)
        self.assertNotEqual(labels[0], labels[3])

    def test_flat_and_incomplete_genes_are_left_out_and_counted(self):
        means, truth = planted(per_shape=10)
        flat = pd.DataFrame({"gene_id": "flat", "condition": "", "time": TIMES, "time_value": 0.0,
                             "n_samples": 3, "mean_vst": 7.0})
        missing = means[means["gene_id"] == "rise_000"].assign(gene_id="partial").iloc[:-1]
        means = pd.concat([means, flat, missing])
        genes = list(truth) + ["flat", "partial", "absent"]
        result = cluster_genes.cluster(means, genes, TIMES, requested=4)
        self.assertEqual(result["excluded"], 3)
        self.assertNotIn("flat", result["genes"])
        self.assertEqual(len(result["genes"]), 40)

    def test_too_few_genes_or_groups_is_skipped_with_a_reason(self):
        means, truth = planted(per_shape=4)
        result = cluster_genes.cluster(means, list(truth), TIMES)
        self.assertEqual(result["status"], "skipped")
        self.assertIn("at least 20 significant genes", result["reason"])

        two_times = means[means["time"].isin(["0", "2"])]
        result = cluster_genes.cluster(two_times, list(truth), TIMES)
        self.assertEqual(result["status"], "skipped")
        self.assertIn("at least 3 groups", result["reason"])

    def test_conditions_are_joined_so_different_responses_separate(self):
        # Same pattern in the reference; opposite patterns in the test condition.
        means_a, truth_a = planted(per_shape=40, shapes={"together": SHAPES["rise"]}, seed=1)
        means_b, truth_b = planted(per_shape=40, shapes={"apart": SHAPES["rise"]}, seed=2)
        means_a = pd.concat([means_a.assign(condition="control"), means_a.assign(condition="treated")])
        reversed_b = means_b.assign(condition="treated",
                                    mean_vst=means_b.groupby("gene_id")["mean_vst"].transform(lambda values: values.iloc[::-1].to_numpy()))
        means = pd.concat([means_a, means_b.assign(condition="control"), reversed_b])
        truth = {**truth_a, **truth_b}
        result = cluster_genes.cluster(means, list(truth), TIMES)
        self.assertEqual([column[0] for column in result["columns"]], ["control"] * 6 + ["treated"] * 6)
        self.assertEqual(result["chosen"], 2)
        self.assertEqual(adjusted_rand([truth[gene] for gene in result["genes"]], result["labels"]), 1.0)

    def test_large_inputs_score_a_fixed_sample(self):
        means, truth = planted(per_shape=800, noise=0.6)
        original = cluster_genes.MAX_CLUSTERS
        cluster_genes.MAX_CLUSTERS = 5  # keep the test quick
        try:
            result = cluster_genes.cluster(means, list(truth), TIMES)
        finally:
            cluster_genes.MAX_CLUSTERS = original
        self.assertTrue(result["sampled"])
        self.assertEqual(result["chosen"], 4)
        self.assertEqual(len(result["labels"]), 3200)
        self.assertEqual(cluster_genes.summary(result)["silhouette_sampled_genes"], 3000)


class ClusterScriptTest(unittest.TestCase):
    """The command-line script on a minimal results folder."""

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="micronet-clustering-"))
        means, truth = planted(per_shape=30)
        means.to_csv(self.directory / "group_means_vst.tsv", sep="\t", index=False)
        pd.DataFrame({"gene_id": list(truth) + ["unchanged"], "padj": 0.001, "max_abs_log2FC": 2.0,
                      "significant": ["TRUE"] * len(truth) + ["FALSE"]}).to_csv(
            self.directory / "deseq2_results.tsv", sep="\t", index=False)
        self.manifest = {"status": "completed", "time": {"column": "time", "levels": TIMES},
                         "outputs": {"results": "deseq2_results.tsv", "group_means": "group_means_vst.tsv"}}
        (self.directory / "manifest.json").write_text(json.dumps(self.manifest))

    def tearDown(self):
        shutil.rmtree(self.directory)

    def run_script(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.directory), *arguments], capture_output=True, text=True)

    def test_writes_the_tables_and_records_them_in_the_manifest(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.directory / "manifest.json").read_text())
        self.assertEqual(manifest["clustering"]["clusters"], 4)
        self.assertEqual(manifest["clustering"]["genes_clustered"], 120)
        for key, name in cluster_genes.OUTPUTS.items():
            self.assertEqual(manifest["outputs"][key], name)
        clusters = pd.read_csv(self.directory / "gene_clusters.tsv", sep="\t")
        self.assertEqual(list(clusters.columns), ["gene_id", "cluster", "padj", "max_abs_log2FC", "distance_to_center"])
        self.assertNotIn("unchanged", set(clusters["gene_id"]))
        profiles = pd.read_csv(self.directory / "cluster_profiles.tsv", sep="\t")
        self.assertEqual(len(profiles), 4 * len(TIMES))
        self.assertFalse(list(self.directory.glob("*.partial")))

    def test_a_chosen_number_outside_two_to_ten_is_refused(self):
        for value in ["1", "11"]:
            result = self.run_script("--clusters", value)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("from 2 to 10", result.stderr)
        self.assertNotIn("clustering", json.loads((self.directory / "manifest.json").read_text()))

    def test_an_incomplete_analysis_is_not_clustered(self):
        (self.directory / "manifest.json").write_text(json.dumps({**self.manifest, "status": "failed"}))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "gene_clusters.tsv").exists())


if __name__ == "__main__":
    unittest.main()
