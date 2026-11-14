"""Renders the vector icon (Tools/Icon/icon.svg) into the app's asset catalog.

    uv run --with pillow python Tools/Icon/make_icon.py [output.png]

Needs `rsvg-convert` (`brew install librsvg`). The PNG is written without an
alpha channel, which an app icon must not have.
"""
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image

SIZE = 1024

here = pathlib.Path(__file__).resolve().parent
default = here.parents[1] / "Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default

with tempfile.TemporaryDirectory() as scratch:
    rendered = pathlib.Path(scratch) / "icon.png"
    subprocess.run(
        ["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE), str(here / "icon.svg"), "-o", str(rendered)],
        check=True,
    )
    image = Image.open(rendered).convert("RGBA")
    flat = Image.new("RGB", image.size, "white")
    flat.paste(image, mask=image.getchannel("A"))
    flat.save(target)

print(f"wrote {target}")
