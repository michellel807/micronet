"""Tests for lib/scripts/rnaseq/plot_results.py and package_results.py.

Both read a real deseq2_analysis.R run on simulated data, so these tests need
Rscript with DESeq2, as installed in the MicroNet Docker image.
"""
import csv
import importlib.util
import json
import os
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

    def test_a_failed_analysis_is_not_packaged(self):
        directory = Path(WORK.name) / "failed-package"
        directory.mkdir()
        (directory / "manifest.json").write_text(json.dumps({"status": "failed"}))
        zip_path = Path(WORK.name) / "failed.zip"
        result = run_script("package_results.py", directory, zip_path, "--job-number", 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(zip_path.exists())


if __name__ == "__main__":
    unittest.main()
