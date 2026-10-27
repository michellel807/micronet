"""Exercise the real scientific stack; run inside the app's Docker image."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

APP_ROOT = Path(__file__).resolve().parents[2]


class AmigaSmokeTest(unittest.TestCase):
    def run_command(self, *arguments, allowed_codes=(0,)):
        result = subprocess.run(
            [str(argument) for argument in arguments], cwd=self.root,
            env={**os.environ, "OPENBLAS_NUM_THREADS": "1", "MPLBACKEND": "Agg"},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
        )
        self.assertIn(result.returncode, allowed_codes, result.stdout)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="micronet-smoke-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "data").mkdir()
        (self.root / "mapping").mkdir()

    def write_inputs(self, wells=None):
        data = (APP_ROOT / "lib/examplefiles/data/exampledata1.txt").read_text().splitlines()
        rows = [row for row in data[2:] if wells is None or row.split("\t")[0] in wells]
        (self.root / "data/smoke.txt").write_text(
            "\n".join("\t".join(row.split("\t")[:17]) for row in data[:2] + rows) + "\n"
        )
        mapping = (APP_ROOT / "lib/examplefiles/mapping/examplemapping1.txt").read_text().splitlines()
        rows = [row.replace("2020-06-22-R1", "smoke") for row in mapping[1:]
                if wells is None or row.split("\t")[0] in wells]
        (self.root / "mapping/smoke.txt").write_text("\n".join(mapping[:1] + rows) + "\n")

    def test_fit_pool_posterior_heatmap_compare_and_hypothesis(self):
        self.write_inputs({"A1", "A2", "B1", "B2"})
        self.run_command("amiga", "fit", "-i", self.root, "--save-gp-data", "-o", "smoke")
        summary = self.root / "summary/smoke_summary.txt"
        self.assertTrue(summary.is_file())
        self.assertTrue((self.root / "derived/smoke_gp_data.txt").is_file())
        self.run_command("amiga", "fit", "-i", self.root, "--pool-by", "Concentration",
                         "--sample-posterior", "-o", "compare")
        self.run_command("python", APP_ROOT / "lib/scripts/otherscripts/simplifyfit.py", summary)
        self.run_command("amiga", "heatmap", "-i", self.root / "summary/smoke_summary_modified.txt",
                         "-o", "heatmap_plot", "-x", "Concentration", "-y", "Isolate",
                         "-v", "Growth Rate", "--kwargs", "cmap:Reds")
        self.assertTrue((self.root / "summary/heatmap_plot.pdf").is_file())
        self.run_command("amiga", "compare", "-i", self.root / "summary/compare_summary.txt",
                         "-o", self.root / "compare-parameters", "-s", "Concentration:Low,High")
        self.assertTrue((self.root / "compare-parameters.txt").is_file())
        # AMIGA can exit 1 on successful hypothesis tests; verify the report too.
        self.run_command("amiga", "test", "-i", self.root, "-s", "Concentration:Low,High",
                         "-y", "H0:Time;H1:Time+Concentration", "-o", "test-hypothesis", allowed_codes=(0, 1))
        self.assertTrue(list((self.root / "models/test-hypothesis").glob("*report.txt")))

    def test_raw_data_plot_and_pdf_rendering(self):
        self.write_inputs()
        self.run_command("amiga", "summarize", "-i", self.root)
        plots = list((self.root / "figures").glob("*.pdf"))
        self.assertTrue(plots)
        png = self.root / "preview.png"
        self.run_command("python", APP_ROOT / "lib/scripts/otherscripts/renderpdf.py", plots[0], png)
        self.assertGreater(png.stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
