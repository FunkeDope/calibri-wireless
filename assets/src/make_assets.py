"""Render the e-ink UI assets for the Kindle calibre companion.

python make_assets.py <calibre_logo.png> <fonts_dir> <out_dir> [icons_dir]

fonts_dir / icons_dir hold Amazon's Ember TTFs and the Kindle's status-bar
SVG icons, pulled from a device with tools/fetch_device_art.py (they are not
redistributable, so they are not in git; the rendered PNGs are). Without
icons_dir the existing batt_*/wifi_* PNGs are left alone. Needs the resvg-py
package for the icons.

Outputs (8-bit grayscale PNGs, sized for a 1236x1648 Paperwhite 5):
  cover.png            600x960 library tile (scriptlet icon, book-cover aspect)
  logo.png             400x400 calibre logo
  logo_small.png       120x120
  btn_bg.png           pill button "Run in background"
  btn_quit.png         pill button "Disconnect & quit"
  chk_off.png/chk_on.png  checkbox row "Keep running until reboot"
  batt_0..10.png, batt_chg.png, wifi_0..5.png  header icons (Kindle artwork)
  dots_0..3.png        activity dots for the Searching screen
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

logo_src, fonts, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)

W = 1236  # screen width, for button widths


def font(name, size):
    return ImageFont.truetype(os.path.join(fonts, name), size)


def to_gray(img):
    # flatten alpha on white, then grayscale
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
        bg.alpha_composite(img)
        img = bg
    return img.convert("L")


def logo(size):
    im = Image.open(logo_src)
    im = to_gray(im)
    # crop to content box so it sits tight, then fit in square
    bbox = Image.eval(im, lambda p: 255 - p).getbbox()
    if bbox:
        im = im.crop(bbox)
    im.thumbnail((size, size), Image.LANCZOS)
    canvas = Image.new("L", (size, size), 255)
    canvas.paste(im, ((size - im.width) // 2, (size - im.height) // 2))
    return canvas


def save(img, name):
    img.save(os.path.join(out, name), optimize=True)
    print("wrote", name, img.size)


# --- logos
save(logo(400), "logo.png")
save(logo(120), "logo_small.png")

# --- library tile (looks like a book cover on the home screen)
# Same 1:1.6 aspect as Kindle book covers so the tile is as tall as the
# books next to it. The home screen shows it at roughly a quarter size, so:
# thin border, the logo filling the top, two big words, no small print.
CW, CH = 600, 960
cover = Image.new("L", (CW, CH), 255)
d = ImageDraw.Draw(cover)
d.rectangle([0, 0, CW - 1, CH - 1], outline=0, width=8)
LG = 500
lg = logo(LG)
cover.paste(lg, ((CW - LG) // 2, 60))
f_title = font("Amazon-Ember-Bold.ttf", 132)
f_name = font("Amazon-Ember-Medium.ttf", 88)
tw = d.textlength("calibre", font=f_title)
d.text(((CW - tw) / 2, 600), "calibre", font=f_title, fill=0)
tw = d.textlength("wireless", font=f_name)
d.text(((CW - tw) / 2, 770), "wireless", font=f_name, fill=0)
save(cover, "cover.png")


# --- pill buttons
def pill(text, w=900, h=128, invert=False, fontsize=44):
    im = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(im)
    r = h // 2
    fill = 0 if invert else 255
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=fill, outline=0, width=5)
    f = font("Amazon-Ember-Medium.ttf", fontsize)
    tw = d.textlength(text, font=f)
    bb = f.getbbox(text)
    th = bb[3] - bb[1]
    d.text(((w - tw) / 2, (h - th) / 2 - bb[1]), text, font=f, fill=255 if invert else 0)
    return im


save(pill("Run in background", invert=True), "btn_bg.png")
save(pill("Disconnect & quit"), "btn_quit.png")
# inverted pills with baked-in labels (runtime white text over black is unreliable in fbink)
save(pill("Type an address…", h=110, invert=True, fontsize=40), "pill_type_address.png")
save(pill("Connect", h=110, invert=True, fontsize=40), "pill_connect.png")


# --- checkbox rows (box + label centered as a group, to line up with the pills)
def check_row(checked, text="Keep running until reboot", w=900, h=110):
    im = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(im)
    box = 64
    f_probe = font("Amazon-Ember-Regular.ttf", 44)
    group_w = box + 34 + d.textlength(text, font=f_probe)
    x0, y0 = int((w - group_w) / 2), (h - box) // 2
    d.rounded_rectangle([x0, y0, x0 + box, y0 + box], radius=10, outline=0, width=5, fill=0 if checked else 255)
    if checked:
        # white tick
        d.line([(x0 + 14, y0 + 34), (x0 + 28, y0 + 48), (x0 + 52, y0 + 18)], fill=255, width=8, joint="curve")
    f = font("Amazon-Ember-Regular.ttf", 44)
    bb = f.getbbox(text)
    d.text((x0 + box + 34, (h - (bb[3] - bb[1])) / 2 - bb[1]), text, font=f, fill=0)
    return im


save(check_row(False), "chk_off.png")
save(check_row(True), "chk_on.png")

# --- header glyphs: the Kindle's own status-bar icons, rasterised from the
# SVGs the 5.17+ UI ships (icons_dir). battery-default.svg draws a fixed
# full fill "M4 6h21v8H4z"; its width is scaled for the 0..10 tenths.
ICONS = sys.argv[4] if len(sys.argv) > 4 else None
BATT_W, BATT_H, WIFI_PX = 56, 35, 42   # ui.lua's ASSET table mirrors these


def svg_png(name, w, h, edit=None):
    import io
    import resvg_py
    s = open(os.path.join(ICONS, name), encoding="utf-8").read()
    if edit:
        s = edit(s)
    png = bytes(resvg_py.svg_to_bytes(svg_string=s, width=w, height=h))
    return to_gray(Image.open(io.BytesIO(png)))


if ICONS:
    FULL = '<path d="M4 6h21v8H4z"/>'
    assert FULL in open(os.path.join(ICONS, "battery-default.svg"), encoding="utf-8").read()
    for lvl in range(11):
        fw = round(21 * lvl / 10)
        part = f'<path d="M4 6h{fw}v8H4z"/>' if fw else ""
        save(svg_png("battery-default.svg", BATT_W, BATT_H, lambda s, part=part: s.replace(FULL, part)), f"batt_{lvl}.png")
    save(svg_png("battery-charging.svg", BATT_W, BATT_H), "batt_chg.png")
    # wifid reports signalStrength N/5; the Kindle itself only has 0..3 bars.
    WIFI = {0: "wifi-offline.svg", 1: "wifi-one.svg", 2: "wifi-one.svg", 3: "wifi-two.svg", 4: "wifi-three.svg", 5: "wifi-three.svg"}
    for bars, name in WIFI.items():
        save(svg_png(name, WIFI_PX, WIFI_PX), f"wifi_{bars}.png")
else:
    print("no icons_dir given: keeping existing batt_*/wifi_* PNGs")

# --- blank widgets: list row pill and keypad key (labels drawn at runtime)
def blank_pill(w=900, h=110, invert=False):
    im = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=h // 2, fill=0 if invert else 255, outline=0, width=5)
    return im


save(blank_pill(), "pill_blank.png")
save(blank_pill(invert=True), "pill_blank_inv.png")


def key(w=170, h=120):
    im = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=18, fill=255, outline=0, width=4)
    return im


save(key(), "key.png")

# entry box for the address keypad
box = Image.new("L", (900, 110), 255)
d = ImageDraw.Draw(box)
d.rounded_rectangle([0, 0, 899, 109], radius=14, fill=255, outline=0, width=4)
save(box, "entry_box.png")

# --- header rule
rule = Image.new("L", (W - 80, 3), 0)
save(rule, "rule.png")

# --- activity dots (searching animation, 4 frames)
for step in range(4):
    im = Image.new("L", (260, 60), 255)
    d = ImageDraw.Draw(im)
    for i in range(3):
        cx = 40 + i * 90
        filled = (i == step % 3) if step < 3 else True
        d.ellipse([cx - 22, 8, cx + 22, 52], fill=0 if filled else 255, outline=0, width=4)
    save(im, f"dots_{step}.png")

print("done")
