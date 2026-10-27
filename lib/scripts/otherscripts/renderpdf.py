"""Render server-generated PDFs without a general-purpose image decoder."""
import json
from pathlib import Path
import sys

import pypdfium2 as pdfium


def render_pdf(source, destination):
    destination = Path(destination)
    outputs = []
    with pdfium.PdfDocument(source) as document:
        for index in range(len(document)):
            output = destination if len(document) == 1 else destination.with_name(
                f"{destination.stem}-{index}{destination.suffix}"
            )
            page = document[index]
            try:
                bitmap = page.render(scale=1)
                try:
                    with bitmap.to_pil() as image:
                        image.save(output)
                finally:
                    bitmap.close()
            finally:
                page.close()
            outputs.append(str(output))
    return outputs


if __name__ == "__main__":
    print(json.dumps(render_pdf(sys.argv[1], sys.argv[2])))
