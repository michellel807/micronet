import importlib.util
from pathlib import Path
import tempfile
import unittest

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

SCRIPT = Path(__file__).resolve().parents[2] / "lib/scripts/otherscripts/gpplot.py"
spec = importlib.util.spec_from_file_location("gpplot", SCRIPT)
gpplot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpplot)


class GpPlotTest(unittest.TestCase):
    def tearDown(self):
        plt.close("all")

    def test_pooled_curves_separate_each_combination(self):
        with tempfile.TemporaryDirectory() as directory:
            rows = [
                {"Strain": strain, "Dose": dose, "Time": time, "mu": offset + time, "Sigma": 0.01}
                for strain, dose, offset in [("WT", 0, 0), ("WT", 10, 1), ("mutant", 0, 2)]
                for time in [2, 0, 1]
            ]
            pd.DataFrame(rows).to_csv(Path(directory) / "plot_gp_data.txt", sep="\t")
            gpplot.plot_gp_data(directory, "condition:(--Fe)", ["Strain", "Dose"])
            lines = plt.gca().get_lines()
            self.assertEqual(len(lines), 3)
            self.assertEqual([line.get_label() for line in lines], [
                "Strain: WT, Dose: 0 Mean", "Strain: WT, Dose: 10 Mean", "Strain: mutant, Dose: 0 Mean"
            ])
            for line in lines:
                self.assertEqual(list(line.get_xdata()), [0, 1, 2])
            self.assertTrue((Path(directory) / "gp_plot.pdf").is_file())

    def test_unpooled_curves_remain_separate_per_well(self):
        with tempfile.TemporaryDirectory() as directory:
            pd.DataFrame([
                {"Sample_ID": sample, "Time": time, "OD_Fit": time / 10}
                for sample in ["A1", "A2"] for time in [1, 0]
            ]).to_csv(Path(directory) / "plot_gp_data.txt", sep="\t", index=False)
            gpplot.plot_gp_data(directory, "condition:(--Fe)")
            self.assertEqual(len(plt.gca().get_lines()), 2)

    def test_single_pooling_column(self):
        with tempfile.TemporaryDirectory() as directory:
            pd.DataFrame([
                {"Strain": strain, "Time": time, "mu": time, "Sigma": 0.01}
                for strain in ["WT", "mutant"] for time in [0, 1]
            ]).to_csv(Path(directory) / "plot_gp_data.txt", sep="\t")
            gpplot.plot_gp_data(directory, "", ["Strain"])
            self.assertEqual(len(plt.gca().get_lines()), 2)

    def test_shared_helpers_draw_a_labeled_mean_and_band(self):
        figure, axes = plt.subplots()
        line = gpplot.draw_gp_curve(axes, [0, 1, 2], [1.0, 2.0, 3.0], [0.5, 0.5, 0.5], "control")
        gpplot.finish_gp_plot(axes, "Gaussian Process Plot", "Predicted OD")
        self.assertEqual(line.get_label(), "control Mean")
        band = axes.collections[0].get_paths()[0].vertices
        self.assertAlmostEqual(band[:, 1].max(), 3.0 + 1.96 * 0.5)
        self.assertAlmostEqual(band[:, 1].min(), 1.0 - 1.96 * 0.5)
        self.assertTrue(axes.xaxis._major_tick_kw.get("gridOn"))
        self.assertEqual(axes.get_legend().get_texts()[0].get_text(), "control Mean")

    def test_style_applies_only_while_drawing(self):
        default = plt.rcParams["axes.titlesize"]
        with tempfile.TemporaryDirectory() as directory:
            pd.DataFrame([{"Strain": "WT", "Time": time, "mu": time, "Sigma": 0.01} for time in [0, 1]]).to_csv(
                Path(directory) / "plot_gp_data.txt", sep="\t")
            gpplot.plot_gp_data(directory, "", ["Strain"])
            self.assertEqual(plt.gca().title.get_fontsize(), 16)
        self.assertEqual(plt.rcParams["axes.titlesize"], default)


if __name__ == "__main__":
    unittest.main()
