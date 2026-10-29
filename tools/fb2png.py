"""Convert a raw Kindle framebuffer dump (8bpp) to PNG.

python fb2png.py <fb.raw> <out.png> [--scale 0.5] [--geom STRIDE WxH]

Default geometry is the Paperwhite 5 (stride 1248, 1236x1648). Other panels:
  PW4 / KT4 / PW3:  --geom 1088 1072x1448
  (stride = /sys/class/graphics/fb0/stride, size from `fbink -e` or ui.log)
"""
import sys

from PIL import Image

src, out = sys.argv[1], sys.argv[2]
scale = float(sys.argv[sys.argv.index("--scale") + 1]) if "--scale" in sys.argv else 1.0
STRIDE, W, H = 1248, 1236, 1648
if "--geom" in sys.argv:
    i = sys.argv.index("--geom")
    STRIDE = int(sys.argv[i + 1])
    W, H = (int(v) for v in sys.argv[i + 2].lower().split("x"))
VH = H * 2
with open(src, "rb") as f:
    data = f.read()
rows = min(VH, len(data) // STRIDE)
im = Image.frombytes("L", (STRIDE, rows), data[: STRIDE * rows]).crop((0, 0, W, min(H, rows)))
if scale != 1.0:
    im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
im.save(out)
print("wrote", out, im.size)
