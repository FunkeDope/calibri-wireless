"""Print a Lua table of glyph advance widths (px) for the header font/size.

python measure_glyphs.py <font.ttf> <px> "<characters>"
"""
import sys

from PIL import ImageFont

path, px, chars = sys.argv[1], int(sys.argv[2]), sys.argv[3]
# fbink's px= is the font pixel size (em height), same as Pillow's size argument.
f = ImageFont.truetype(path, px)
items = []
for ch in chars:
    items.append(f'["{ch}"]={f.getlength(ch):.2f}')
print("{ " + ", ".join(items) + " }")
