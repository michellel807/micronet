"""Tests for lib/scripts/rnaseq/plot_results.py and package_results.py.

Both read a real deseq2_analysis.R run on simulated data, so these tests need
Rscript with DESeq2, as installed in the MicroNet Docker image.
"""
import csv
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "lib/scripts/rnaseq"
RSCRIPT = os.environ.get("RSCRIPT_EXECUTABLE") or shutil.which("Rscript")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


simulation = load("rnaseq_simulation", ROOT / "test/scripts/rnaseq_simulation.py")
plots = load("rnaseq_plot_results", SCRIPTS / "plot_results.py")
WORK = None
ANALYSIS = None


def setUpModule():
    global WORK, ANALYSIS
    if not RSCRIPT:
        return
    WORK = tempfile.TemporaryDirectory(prefix="micronet-rnaseq-outputs-")
    inputs = Path(WORK.name) / "inputs"
    counts, metadata = simulation.write_inputs(simulation.simulate(seed=41), inputs)
    config = inputs / "config.json"
    config.write_text(json.dumps({"reference_level": "control", "test_level": "treated"}))
    ANALYSIS = Path(WORK.name) / "analysis"
    subprocess.run([RSCRIPT, str(SCRIPTS / "deseq2_analysis.R"), "--counts", str(counts), "--metadata", str(metadata),
                    "--config", str(config), "--out", str(ANALYSIS)], check=True, capture_output=True)


def tearDownModule():
    if WORK:
        WORK.cleanup()


def fresh_copy(name):
    """Each test works on its own copy of the analysis outputs."""
    directory = Path(WORK.name) / name
    shutil.copytree(ANALYSIS, directory)
    return directory


def run_script(script, *arguments):
    return subprocess.run([sys.executable, str(SCRIPTS / script), *map(str, arguments)], capture_output=True, text=True)


@unittest.skipUnless(RSCRIPT, "Rscript is not installed; run these tests inside the MicroNet Docker image.")
class PlotResultsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = fresh_copy("plots")
        result = run_script("plot_results.py", cls.directory)
        assert result.returncode == 0, result.stderr

    def test_every_plot_is_a_pdf(self):
        for name in ["pca.pdf", "ma_plot.pdf", "volcano_plot.pdf"]:
            self.assertEqual((self.directory / name).read_bytes()[:5], b"%PDF-", name)

    def test_pca_matches_an_independent_eigendecomposition(self):
        vst = plots.read_table(self.directory / "vst_all.tsv")
        coordinates = pd.read_csv(self.directory / "pca_coordinates.tsv", sep="\t", index_col="sample")
        top = vst.loc[vst.var(axis=1).sort_values(ascending=False).index[:plots.PCA_TOP_GENES]].T
        centred = (top - top.mean()).to_numpy()
        eigenvalues, eigenvectors = np.linalg.eigh(np.cov(centred, rowvar=False))
        for component, column in enumerate(["PC1", "PC2"]):
            expected = centred @ eigenvectors[:, -1 - component]
            # Principal components are defined only up to sign.
            sign = np.sign(expected @ coordinates[column].to_numpy())
            np.testing.assert_allclose(coordinates[column].to_numpy(), sign * expected, rtol=1e-6, atol=1e-8)

    def test_pca_separates_the_simulated_conditions(self):
        coordinates = pd.read_csv(self.directory / "pca_coordinates.tsv", sep="\t", index_col="sample")
        pc1 = coordinates.groupby("condition")["PC1"]
        self.assertTrue(pc1.max().min() < pc1.min().max(), "PC1 should place the conditions on opposite sides")
        sizes = pd.read_csv(self.directory / "size_factors.tsv", sep="\t", index_col="sample")["condition"]
        pd.testing.assert_series_equal(coordinates["condition"].sort_index(), sizes.sort_index())

    def test_no_significant_genes_still_plots(self):
        directory = fresh_copy("no-significant")
        results = pd.read_csv(directory / "deseq2_results.tsv", sep="\t")
        results["significant"] = False
        results.to_csv(directory / "deseq2_results.tsv", sep="\t", index=False)
        result = run_script("plot_results.py", directory)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_failed_analysis_is_not_plotted(self):
        directory = Path(WORK.name) / "failed-plots"
        directory.mkdir()
        (directory / "manifest.json").write_text(json.dumps({"status": "failed"}))
        result = run_script("plot_results.py", directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete", result.stderr)


@unittest.skipUnless(RSCRIPT, "Rscript is not installed; run these tests inside the MicroNet Docker image.")
class SilhouetteBaselineReadmeTest(unittest.TestCase):
    CLUSTERING = {"status": "completed", "chosen_by": "silhouette", "clusters": 3, "genes_clustered": 100,
                  "genes_excluded": 0, "cluster_sizes": [40, 35, 25], "silhouette": 0.35}

    def setUp(self):
        self.package = load("rnaseq_package_results", SCRIPTS / "package_results.py")

    def test_the_baseline_appears_only_when_it_was_run(self):
        self.assertNotIn("reliability", "\n".join(self.package.clustering_lines(self.CLUSTERING)))
        checked = {**self.CLUSTERING, "silhouette_baseline": {"k": 3, "actual": 0.35, "shuffled_mean": 0.19,
                                                              "difference": 0.16, "shuffles": 5}}
        text = "\n".join(self.package.clustering_lines(checked))
        self.assertIn("Silhouette reliability check (k = 3):", text)
        self.assertIn("Actual silhouette: 0.35", text)
        self.assertIn("Shuffled baseline (average of 5): 0.19", text)
        self.assertIn("Difference: +0.16", text)


class PackageResultsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = fresh_copy("package")
        cls.manifest = json.loads((cls.directory / "manifest.json").read_text())
        cls.zip_path = Path(WORK.name) / "results.zip"
        result = run_script("package_results.py", cls.directory, cls.zip_path, "--job-number", 812)
        assert result.returncode == 0, result.stderr
        cls.readme = (cls.directory / "README.txt").read_text()

    def test_zip_holds_every_result_file_in_one_folder(self):
        with zipfile.ZipFile(self.zip_path) as archive:
            names = archive.namelist()
            self.assertEqual(sorted(names), sorted(f"rnaseq_results_job812/{path.name}" for path in self.directory.iterdir()))
            self.assertEqual(archive.read("rnaseq_results_job812/deseq2_results.tsv"),
                             (self.directory / "deseq2_results.tsv").read_bytes())
        self.assertFalse(self.zip_path.with_name(self.zip_path.name + ".partial").exists())

    def test_significant_genes_are_the_significant_rows_verbatim(self):
        with open(self.directory / "deseq2_results.tsv") as handle:
            rows = list(csv.reader(handle, delimiter="\t"))
        column = rows[0].index("significant")
        expected = [rows[0]] + [row for row in rows[1:] if row[column] == "TRUE"]
        with open(self.directory / "significant_genes.tsv") as handle:
            self.assertEqual(list(csv.reader(handle, delimiter="\t")), expected)
        self.assertEqual(len(expected) - 1, self.manifest["genes"]["significant"])

    def test_readme_reports_the_manifest(self):
        genes = self.manifest["genes"]
        for text in ["Job #812", "Design formula: ~ condition", "log2(treated / control)",
                     "higher expression in treated than in control",
                     f"In the count matrix: {genes['in_input']}", f"Tested: {genes['tested']}",
                     f"Significant: {genes['significant']} ({genes['significant_up']} higher and "
                     f"{genes['significant_down']} lower in treated)",
                     "adjusted p-value (padj) < 0.05", f"DESeq2 {self.manifest['versions']['DESeq2']}",
                     "Genome Biology 15:550"]:
            self.assertIn(text, self.readme)
        for name in ["vst_significant.tsv", "significant_genes.tsv", "manifest.json"]:
            self.assertIn(f"  {name}\n", self.readme)

    def test_readme_lists_analysis_warnings(self):
        directory = fresh_copy("package-warnings")
        manifest = json.loads((directory / "manifest.json").read_text())
        manifest["warnings"] = ["some genes did not converge"]
        (directory / "manifest.json").write_text(json.dumps(manifest))
        result = run_script("package_results.py", directory, Path(WORK.name) / "warnings.zip", "--job-number", 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("  - some genes did not converge", (directory / "README.txt").read_text())

    def test_significant_genes_are_tested_for_enrichment_by_direction(self):
        directory = fresh_copy("enrichment")
        annotations = Path(WORK.name) / "two-annotations.tsv"
        simulation.simulate_annotations(simulation.simulate(seed=41), seed=41).to_csv(annotations, sep="\t", index=False)
        for script, *arguments in [("enrichment.py", "--annotations", annotations), ("plot_results.py",),
                                   ("package_results.py", Path(WORK.name) / "enrichment.zip", "--job-number", 4)]:
            result = run_script(script, directory, *arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
        significant = pd.read_csv(directory / "enrichment_significant.tsv", sep="\t")
        found = set(zip(significant["gene_set"], significant["term"]))
        self.assertTrue({("higher in treated", "ko99001"), ("lower in treated", "ko99002")} <= found)
        manifest = json.loads((directory / "manifest.json").read_text())
        tested = [(name, source) for name in ("higher in treated", "lower in treated") for source in ("COG", "KEGG")]
        pages = re.findall(rb"/Type\s*/Page\b(?!s)", (directory / "enrichment.pdf").read_bytes())
        self.assertEqual(len(pages), len(tested) - len(manifest["enrichment"]["skipped"]))
        readme = (directory / "README.txt").read_text()
        self.assertIn("higher in treated (", readme)
        self.assertIn("Simulated pathway induced in treated (ko99001)", readme)

    def test_a_failed_analysis_is_not_packaged(self):
        directory = Path(WORK.name) / "failed-package"
        directory.mkdir()
        (directory / "manifest.json").write_text(json.dumps({"status": "failed"}))
        zip_path = Path(WORK.name) / "failed.zip"
        result = run_script("package_results.py", directory, zip_path, "--job-number", 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(zip_path.exists())


@unittest.skipUnless(RSCRIPT, "Rscript is not installed; run these tests inside the MicroNet Docker image.")
class TimeCourseOutputsTest(unittest.TestCase):
    """Plots and packaging for a condition-by-time analysis."""

    @classmethod
    def setUpClass(cls):
        inputs = Path(WORK.name) / "time-inputs"
        experiment = simulation.simulate_time_course(seed=91, n_genes=1200)
        counts, metadata = simulation.write_inputs(experiment, inputs)
        annotations = inputs / "annotations.tsv"
        simulation.simulate_annotations(experiment, seed=91).to_csv(annotations, sep="\t", index=False)
        config = inputs / "config.json"
        config.write_text(json.dumps({"experiment_type": "condition_by_time", "reference_level": "control", "test_level": "treated"}))
        cls.directory = Path(WORK.name) / "time-analysis"
        subprocess.run([RSCRIPT, str(SCRIPTS / "deseq2_analysis.R"), "--counts", str(counts), "--metadata", str(metadata),
                        "--config", str(config), "--out", str(cls.directory)], check=True, capture_output=True)
        result = run_script("cluster_genes.py", cls.directory)
        assert result.returncode == 0, result.stderr
        result = run_script("gp_trajectories.py", cls.directory)
        assert result.returncode == 0, result.stderr
        result = run_script("enrichment.py", cls.directory, "--annotations", annotations)
        assert result.returncode == 0, result.stderr
        result = run_script("plot_results.py", cls.directory)
        assert result.returncode == 0, result.stderr
        cls.zip_path = Path(WORK.name) / "time-results.zip"
        result = run_script("package_results.py", cls.directory, cls.zip_path, "--job-number", 9)
        assert result.returncode == 0, result.stderr
        cls.readme = (cls.directory / "README.txt").read_text()

    def test_time_course_plots_replace_ma_and_volcano(self):
        for name in ["pca.pdf", "top_gene_trajectories.pdf"]:
            self.assertEqual((self.directory / name).read_bytes()[:5], b"%PDF-", name)
        self.assertFalse((self.directory / "ma_plot.pdf").exists())
        self.assertFalse((self.directory / "volcano_plot.pdf").exists())

    def test_pca_coordinates_record_condition_and_time(self):
        coordinates = pd.read_csv(self.directory / "pca_coordinates.tsv", sep="\t", index_col="sample")
        self.assertEqual(list(coordinates.columns[:2]), ["condition", "time"])
        self.assertEqual(sorted(coordinates["time"].unique()), [0, 6, 24])

    def test_zip_includes_group_means(self):
        with zipfile.ZipFile(self.zip_path) as archive:
            names = {Path(name).name for name in archive.namelist()}
        self.assertTrue({"group_means_vst.tsv", "top_gene_trajectories.pdf", "significant_genes.tsv"} <= names)

    def test_readme_explains_the_interaction_test(self):
        self.assertIn("likelihood ratio test of the condition-by-time interaction", self.readme)
        self.assertIn("Time points (time), treated as categories: 0, 6, 24", self.readme)
        self.assertIn("log2FC_treated_vs_control_at_time_T", self.readme)
        self.assertIn("group_means_vst.tsv", self.readme)
        self.assertNotIn("higher and", self.readme)

    def test_significant_genes_are_clustered_across_both_conditions(self):
        manifest = json.loads((self.directory / "manifest.json").read_text())
        clustering = manifest["clustering"]
        self.assertEqual(clustering["status"], "completed")
        self.assertEqual(clustering["chosen_by"], "silhouette")
        self.assertEqual(len(clustering["groups"]), 6, "both conditions at three time points")
        clusters = pd.read_csv(self.directory / "gene_clusters.tsv", sep="\t")
        significant = pd.read_csv(self.directory / "significant_genes.tsv", sep="\t")
        self.assertEqual(len(clusters) + clustering["genes_excluded"], len(significant))
        self.assertTrue(set(clusters["gene_id"]) <= set(significant["gene_id"]))
        self.assertEqual(clustering["cluster_sizes"], clusters["cluster"].value_counts().sort_index().tolist())
        profiles = pd.read_csv(self.directory / "cluster_profiles.tsv", sep="\t")
        self.assertEqual(len(profiles), clustering["clusters"] * 6)
        # Each cluster's average z-scores sum to zero across its groups.
        np.testing.assert_allclose(profiles.groupby("cluster")["mean_z"].sum(), 0, atol=1e-9)

    def test_zip_and_readme_include_the_clusters(self):
        with zipfile.ZipFile(self.zip_path) as archive:
            names = {Path(name).name for name in archive.namelist()}
        self.assertTrue({"gene_clusters.tsv", "cluster_profiles.tsv", "cluster_selection.tsv",
                         "cluster_trajectories.pdf", "cluster_selection.pdf"} <= names)
        for name in ["cluster_trajectories.pdf", "cluster_selection.pdf"]:
            self.assertEqual((self.directory / name).read_bytes()[:5], b"%PDF-", name)
        self.assertIn("CLUSTERS", self.readme)
        self.assertIn("highest\n  silhouette score", self.readme)

    def test_each_cluster_gets_a_curve_per_condition_and_a_difference(self):
        manifest = json.loads((self.directory / "manifest.json").read_text())
        gp, clusters = manifest["gaussian_process"], manifest["clustering"]["clusters"]
        self.assertEqual(gp["status"], "completed")
        self.assertEqual(gp["conditions"], ["control", "treated"])
        curves = pd.read_csv(self.directory / "cluster_gp_curves.tsv", sep="\t")
        self.assertEqual(len(curves), clusters * 2 * 100)
        self.assertTrue((curves["lower"] <= curves["mean"]).all() and (curves["mean"] <= curves["upper"]).all())
        self.assertEqual((curves["time"].min(), curves["time"].max()), (0, 24))
        points = pd.read_csv(self.directory / "cluster_gp_points.tsv", sep="\t")
        self.assertEqual(len(points), clusters * 18, "one point per sample per cluster")
        differences = pd.read_csv(self.directory / "cluster_gp_differences.tsv", sep="\t")
        self.assertEqual(len(differences), clusters * 100)
        self.assertEqual(sorted(gp["difference"]["intervals"]), sorted(str(number) for number in range(1, clusters + 1)))
        with zipfile.ZipFile(self.zip_path) as archive:
            names = {Path(name).name for name in archive.namelist()}
        self.assertTrue({"cluster_gp_points.tsv", "cluster_gp_curves.tsv", "cluster_gp_fits.tsv", "cluster_gp_differences.tsv",
                         "cluster_gp_curves.pdf", "cluster_gp_differences.pdf"} <= names)
        self.assertIn("GAUSSIAN PROCESS CURVES", self.readme)
        self.assertIn("treated minus control", self.readme)
        self.assertIn("Rasmussen CE", self.readme)

    def test_gp_plots_have_one_growth_style_page_per_cluster(self):
        clusters = json.loads((self.directory / "manifest.json").read_text())["clustering"]["clusters"]
        for name in ["cluster_gp_curves.pdf", "cluster_gp_differences.pdf"]:
            pages = re.findall(rb"/Type\s*/Page\b(?!s)", (self.directory / name).read_bytes())
            self.assertEqual(len(pages), clusters, name)

        captured = []

        class Capture:
            def __init__(self, path):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *exception):
                return False

            def savefig(self, figure, **options):
                captured.append([(axes.get_title(), [line.get_label() for line in axes.get_lines()],
                                  axes.xaxis._major_tick_kw.get("gridOn"), tuple(figure.get_size_inches()),
                                  list(axes.get_xticks()))
                                 for axes in figure.axes][0])

        original = plots.PdfPages
        plots.PdfPages = Capture
        try:
            directory = Path(WORK.name) / "time-gp-style"
            shutil.copytree(self.directory, directory, dirs_exist_ok=True)
            plots.main(directory)
        finally:
            plots.PdfPages = original
        captured = [page for page in captured if page[0].startswith("Gaussian Process")]
        curves, differences = captured[:clusters], captured[clusters:]
        title, labels, grid, size, ticks = curves[0]
        # Regular ticks like the growth GP plot, not only the measured times 0, 6 and 24.
        self.assertGreater(len(ticks), 3)
        self.assertEqual(len(set(np.round(np.diff(ticks), 9))), 1)
        self.assertEqual(title.split(" (")[0], "Gaussian Process Plot: Cluster 1")
        self.assertEqual(labels, ["control Mean", "treated Mean"])
        self.assertTrue(grid)
        self.assertEqual(size, (10.0, 6.0))
        self.assertEqual(differences[0][0], "Gaussian Process Difference: Cluster 1")
        self.assertIn("treated minus control Mean", differences[0][1])

    def test_clusters_are_tested_for_enrichment(self):
        manifest = json.loads((self.directory / "manifest.json").read_text())
        enrichment = manifest["enrichment"]
        self.assertEqual(enrichment["status"], "completed")
        clusters = manifest["clustering"]["clusters"]
        self.assertEqual([entry["name"] for entry in enrichment["gene_sets"]],
                         [f"cluster {number}" for number in range(1, clusters + 1)])
        significant = pd.read_csv(self.directory / "enrichment_significant.tsv", sep="\t")
        # Condition-by-time selects the genes that change only in the second condition.
        self.assertIn("ko99002", set(significant["term"]))
        self.assertNotIn("ko99001", set(significant["term"]))
        with zipfile.ZipFile(self.zip_path) as archive:
            names = {Path(name).name for name in archive.namelist()}
        self.assertTrue({"enrichment_results.tsv", "enrichment_significant.tsv", "enrichment.pdf"} <= names)
        self.assertIn("FUNCTIONAL ENRICHMENT", self.readme)
        self.assertIn("Fisher RA (1922)", self.readme)

    def test_too_few_significant_genes_skips_clustering_and_says_why(self):
        directory = Path(WORK.name) / "time-few-significant"
        shutil.copytree(self.directory, directory)
        results = pd.read_csv(directory / "deseq2_results.tsv", sep="\t")
        results["significant"] = results.index < 5
        results.to_csv(directory / "deseq2_results.tsv", sep="\t", index=False)
        for script, *arguments in [("cluster_genes.py",), ("gp_trajectories.py",), ("plot_results.py",),
                                   ("package_results.py", Path(WORK.name) / "few.zip", "--job-number", 3)]:
            result = run_script(script, directory, *arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((directory / "manifest.json").read_text())
        self.assertEqual(manifest["clustering"]["status"], "skipped")
        self.assertNotIn("gene_clusters", manifest["outputs"])
        self.assertFalse((directory / "gene_clusters.tsv").exists())
        readme = (directory / "README.txt").read_text()
        self.assertIn("Not clustered: Clustering needs at least 20 significant genes", readme)
        self.assertEqual(manifest["gaussian_process"]["status"], "skipped")
        self.assertFalse((directory / "cluster_gp_curves.tsv").exists())
        self.assertFalse((directory / "cluster_gp_curves.pdf").exists())
        self.assertIn("No curves: The genes were not clustered", readme)

    def test_two_condition_results_are_not_clustered(self):
        directory = fresh_copy("two-condition-clustering")
        before = (directory / "manifest.json").read_text()
        for script in ["cluster_genes.py", "gp_trajectories.py"]:
            result = run_script(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((directory / "manifest.json").read_text(), before)
        self.assertFalse((directory / "gene_clusters.tsv").exists())

    def test_no_significant_genes_still_plots_trajectories(self):
        directory = Path(WORK.name) / "time-no-significant"
        shutil.copytree(self.directory, directory)
        results = pd.read_csv(directory / "deseq2_results.tsv", sep="\t")
        results["significant"] = False
        results.to_csv(directory / "deseq2_results.tsv", sep="\t", index=False)
        result = run_script("plot_results.py", directory)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
