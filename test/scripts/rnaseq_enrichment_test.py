"""Tests for lib/scripts/rnaseq/enrichment.py (no R needed)."""
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
from scipy.stats import fisher_exact

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "lib/scripts/rnaseq/enrichment.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


enrichment = load("enrichment", SCRIPT)
simulation = load("rnaseq_simulation", ROOT / "test/scripts/rnaseq_simulation.py")


def results_table(genes, significant=(), up=()):
    table = pd.DataFrame({"log2FoldChange": [2.0 if gene in up else -2.0 for gene in genes],
                          "significant": [gene in significant for gene in genes]},
                         index=pd.Index(genes, name="gene_id"))
    return table


def annotation_table(rows):
    return pd.DataFrame(rows, columns=["gene_id", "source", "term", "description"])


TWO_CONDITION = {"experiment_type": "two_condition", "contrast": {"test_level": "treated"},
                 "parameters": {"alpha": 0.05}}


class FisherTest(unittest.TestCase):
    def test_hypergeometric_tail_equals_fishers_exact_test(self):
        rng = np.random.default_rng(0)
        universe = {f"g{index}" for index in range(200)}
        for _ in range(60):
            term = set(rng.choice(sorted(universe), size=int(rng.integers(3, 60)), replace=False))
            members = set(rng.choice(sorted(universe), size=int(rng.integers(3, 80)), replace=False))
            row = enrichment.enrich(members, {"T": term}, universe, {}, 0.05).iloc[0]
            k, n, big_k, total = (row[key] for key in ("set_genes_with_term", "set_genes", "term_genes", "universe_genes"))
            table = [[k, n - k], [big_k - k, total - n - big_k + k]]
            self.assertAlmostEqual(row["pvalue"], fisher_exact(table, alternative="greater")[1], places=12)

    def test_benjamini_hochberg_within_each_set_and_source(self):
        universe = {f"g{index}" for index in range(100)}
        members = {f"g{index}" for index in range(20)}
        terms = {"strong": {f"g{index}" for index in range(15)}, "weak": {f"g{index}" for index in range(15, 40)},
                 "none": {f"g{index}" for index in range(60, 90)}}
        table = enrichment.enrich(members, terms, universe, {}, 0.05).set_index("term")
        ordered = table["pvalue"].sort_values()
        expected = np.minimum.accumulate((ordered * 3 / np.arange(1, 4))[::-1])[::-1].clip(upper=1)
        np.testing.assert_allclose(table.loc[ordered.index, "padj"], expected)
        self.assertTrue(table.loc["strong", "significant"])
        self.assertFalse(table.loc["none", "significant"])
        self.assertEqual(table.loc["none", "set_genes_with_term"], 0)
        self.assertAlmostEqual(table.loc["strong", "expected"], 20 * 15 / 100)
        self.assertEqual(table.loc["strong", "genes"].split(";")[:2], ["g0", "g1"])

    def test_term_size_limits(self):
        universe = {f"g{index}" for index in range(1000)}
        terms = {"tiny": {"g1", "g2"}, "ok": {f"g{index}" for index in range(10)},
                 "huge": {f"g{index}" for index in range(600)}}
        table = enrichment.enrich({f"g{index}" for index in range(50)}, terms, universe, {}, 0.05)
        self.assertEqual(table["term"].tolist(), ["ok"])


class AnalysisTest(unittest.TestCase):
    def test_universe_is_tested_genes_annotated_in_each_source(self):
        genes = [f"g{index}" for index in range(10)]
        results = results_table(genes, significant=genes[:5], up=genes[:5])
        annotations = annotation_table(
            [(gene, "KEGG", "k1", "") for gene in genes[:6]] + [("untested", "KEGG", "k1", "")]
            + [(gene, "COG", "C", "") for gene in genes[:4]] + [(gene, "COG", "D", "") for gene in genes[4:8]])
        table, summary = enrichment.analyze(TWO_CONDITION, results, annotations)
        self.assertEqual(summary["sources"]["KEGG"]["annotated_tested_genes"], 6)
        self.assertEqual(summary["sources"]["COG"]["annotated_tested_genes"], 8)
        kegg = table[(table["source"] == "KEGG") & (table["gene_set"] == "higher in treated")].iloc[0]
        self.assertEqual((kegg["universe_genes"], kegg["term_genes"], kegg["set_genes"]), (6, 6, 5))

    def test_two_condition_sets_split_by_direction_and_small_sets_are_skipped(self):
        genes = [f"g{index}" for index in range(40)]
        results = results_table(genes, significant=genes[:12], up=genes[:10])
        annotations = annotation_table([(gene, "KEGG", "k1", "Pathway one") for gene in genes[:20]]
                                       + [(gene, "KEGG", "k2", "") for gene in genes[20:]])
        table, summary = enrichment.analyze(TWO_CONDITION, results, annotations)
        self.assertEqual([entry["name"] for entry in summary["gene_sets"]], ["higher in treated", "lower in treated"])
        self.assertEqual(set(table["gene_set"]), {"higher in treated"})
        self.assertEqual(summary["skipped"][0]["gene_set"], "lower in treated")
        self.assertIn("at least 3", summary["skipped"][0]["reason"])
        self.assertEqual(table.set_index("term").loc["k1", "description"], "Pathway one")

    def test_time_courses_use_clusters_or_all_significant_genes(self):
        genes = [f"g{index}" for index in range(30)]
        results = results_table(genes, significant=genes[:20])
        clusters = pd.DataFrame({"gene_id": genes[:20], "cluster": [1] * 12 + [2] * 8})
        manifest = {"experiment_type": "time_course", "parameters": {"alpha": 0.05}, "clustering": {"status": "completed"}}
        self.assertEqual(list(enrichment.gene_sets(manifest, results, clusters)), ["cluster 1", "cluster 2"])
        manifest["clustering"] = {"status": "skipped"}
        self.assertEqual(enrichment.gene_sets(manifest, results, None), {"all significant genes": genes[:20]})

    def test_no_matching_annotations_is_skipped_with_a_reason(self):
        results = results_table(["a", "b", "c"], significant=["a", "b", "c"], up=["a", "b", "c"])
        table, summary = enrichment.analyze(TWO_CONDITION, results, annotation_table([("zzz", "KEGG", "k", "")]))
        self.assertIsNone(table)
        self.assertEqual(summary["status"], "skipped")
        self.assertIn("None of the annotated gene IDs", summary["reason"])

    def test_planted_enrichment_is_found_and_false_positives_are_rare(self):
        found, false_terms, tests = 0, 0, 0
        for seed in range(5):
            experiment = simulation.simulate(seed=seed, n_genes=1500)
            truth = experiment.truth
            results = pd.DataFrame({"log2FoldChange": truth["true_lfc"], "significant": truth["is_de"]})
            annotations = simulation.simulate_annotations(experiment, seed=seed)
            table, _ = enrichment.analyze(TWO_CONDITION, results, annotations)
            significant = table[table["significant"]]
            found += {("higher in treated", "ko99001"), ("lower in treated", "ko99002"),
                      ("higher in treated", "X")} <= set(zip(significant["gene_set"], significant["term"]))
            planted = table["term"].isin(["ko99001", "ko99002", "X"])
            false_terms += int(significant[~significant["term"].isin(["ko99001", "ko99002", "X"])].shape[0])
            tests += int((~planted).sum())
        self.assertEqual(found, 5)
        self.assertLess(false_terms / tests, 0.02)


class AnnotationFileTest(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="micronet-enrichment-"))

    def tearDown(self):
        shutil.rmtree(self.directory)

    def test_terms_split_on_semicolons_duplicates_dropped_and_source_optional(self):
        path = self.directory / "annotations.csv"
        path.write_text("Gene_ID,Term,Description\n g1 , A; B ,First\ng1,A,\ng2,B,\n,C,\ng3,,\n")
        table = enrichment.read_annotations(path)
        self.assertEqual(sorted(zip(table["gene_id"], table["term"])), [("g1", "A"), ("g1", "B"), ("g2", "B")])
        self.assertEqual(set(table["source"]), {"annotation"})
        self.assertEqual(table.set_index(["gene_id", "term"]).loc[("g1", "A"), "description"], "First")

    def test_missing_columns_are_explained(self):
        path = self.directory / "annotations.tsv"
        path.write_text("gene\tpathway\ng1\tA\n")
        with self.assertRaisesRegex(enrichment.AnnotationError, "gene_id, term"):
            enrichment.read_annotations(path)

    def test_script_writes_tables_and_manifest_and_removes_stale_files(self):
        experiment = simulation.simulate(seed=3, n_genes=800)
        results = pd.DataFrame({"baseMean": 100.0, "log2FoldChange": experiment.truth["true_lfc"],
                                "significant": np.where(experiment.truth["is_de"], "TRUE", "FALSE")})
        results.to_csv(self.directory / "deseq2_results.tsv", sep="\t")
        simulation.simulate_annotations(experiment, seed=3).to_csv(self.directory / "annotations.tsv", sep="\t", index=False)
        manifest = {"status": "completed", **TWO_CONDITION, "outputs": {"results": "deseq2_results.tsv"}}
        (self.directory / "manifest.json").write_text(json.dumps(manifest))
        run = lambda path: subprocess.run([sys.executable, str(SCRIPT), str(self.directory), "--annotations", str(path)],
                                          capture_output=True, text=True)
        result = run(self.directory / "annotations.tsv")
        self.assertEqual(result.returncode, 0, result.stderr)
        written = json.loads((self.directory / "manifest.json").read_text())
        self.assertEqual(written["enrichment"]["status"], "completed")
        self.assertEqual(written["enrichment"]["annotation_file"], "annotations.tsv")
        significant = pd.read_csv(self.directory / "enrichment_significant.tsv", sep="\t")
        self.assertIn("ko99001", set(significant["term"]))
        self.assertTrue(significant["significant"].all())
        self.assertFalse(list(self.directory.glob("*.partial")))

        (self.directory / "none.tsv").write_text("gene_id\tterm\nnot_a_gene\tA\n")
        result = run(self.directory / "none.tsv")
        self.assertEqual(result.returncode, 0, result.stderr)
        written = json.loads((self.directory / "manifest.json").read_text())
        self.assertEqual(written["enrichment"]["status"], "skipped")
        self.assertNotIn("enrichment_results", written["outputs"])
        self.assertFalse((self.directory / "enrichment_results.tsv").exists())

        (self.directory / "bad.tsv").write_text("gene\tpathway\ng1\tA\n")
        result = run(self.directory / "bad.tsv")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gene_id, term", result.stderr)


if __name__ == "__main__":
    unittest.main()
