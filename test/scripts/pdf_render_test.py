import importlib.util
from pathlib import Path
import tempfile
import unittest

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from PIL import Image, ImageStat

SCRIPT = Path(__file__).resolve().parents[2] / "lib/scripts/otherscripts/renderpdf.py"
spec = importlib.util.spec_from_file_location("renderpdf", SCRIPT)
renderpdf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderpdf)


class PdfRenderTest(unittest.TestCase):
    def test_every_pdf_page_has_a_nonempty_preview(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "plots.pdf"
            with PdfPages(source) as pdf:
                for title in ["First plot", "Second plot"]:
                    figure, axes = plt.subplots()
                    axes.plot([0, 1, 2], [0, 1, 0])
                    axes.set_title(title)
                    pdf.savefig(figure)
                    plt.close(figure)
            outputs = renderpdf.render_pdf(source, root / "preview.png")
            self.assertEqual([Path(path).name for path in outputs], ["preview-0.png", "preview-1.png"])
            for output in outputs:
                with Image.open(output) as image:
                    self.assertEqual(image.format, "PNG")
                    self.assertGreater(min(image.size), 100)
                    self.assertGreater(max(ImageStat.Stat(image).stddev), 1)


if __name__ == "__main__":
    unittest.main()
