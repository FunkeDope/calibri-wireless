"""Render the e-ink UI assets for the Kindle calibre companion.

python make_assets.py <calibre_logo.png> <fonts_dir> <out_dir>

Outputs (8-bit grayscale PNGs, sized for a 1236x1648 Paperwhite 5):
  cover.png            600x800 library tile (scriptlet icon)
  logo.png             400x400 calibre logo
  logo_small.png       120x120
  btn_bg.png           pill button "Run in background"
  btn_quit.png         pill button "Disconnect & quit"
  chk_off.png/chk_on.png  checkbox row "Keep running forever"
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
cover = Image.new("L", (600, 800), 255)
d = ImageDraw.Draw(cover)
# The home screen shows this at roughly a quarter size, so: thin border,
# the logo filling the top, and two big words. No small print.
d.rectangle([0, 0, 599, 799], outline=0, width=8)
LG = 480
lg = logo(LG)
cover.paste(lg, ((600 - LG) // 2, 28))
f_title = font("Amazon-Ember-Bold.ttf", 128)
f_name = font("Amazon-Ember-Medium.ttf", 84)
tw = d.textlength("calibre", font=f_title)
d.text(((600 - tw) / 2, 500), "calibre", font=f_title, fill=0)
tw = d.textlength("wireless", font=f_name)
d.text(((600 - tw) / 2, 660), "wireless", font=f_name, fill=0)
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
def check_row(checked, text="Keep running forever", w=900, h=110):
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

# --- header glyphs: battery (0..10 tenths, + charging) and Wi-Fi bars (0..5)
def battery(level10, charging=False, w=66, h=32):
    im = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(im)
    body_w = w - 8
    d.rounded_rectangle([0, 0, body_w, h - 1], radius=6, outline=0, width=4)
    d.rounded_rectangle([body_w + 1, h // 2 - 7, w - 1, h // 2 + 7], radius=3, fill=0)  # nub
    inner = max(0, int((body_w - 12) * level10 / 10))
    if inner > 0:
        d.rounded_rectangle([6, 6, 6 + inner, h - 7], radius=3, fill=0)
    if charging:
        # lightning bolt, inverted over the fill
        pts = [(w * 0.52, 3), (w * 0.30, h * 0.58), (w * 0.47, h * 0.58), (w * 0.40, h - 4), (w * 0.64, h * 0.40), (w * 0.47, h * 0.40)]
        d.polygon(pts, fill=255, outline=0)
    return im


for lvl in range(11):
    save(battery(lvl), f"batt_{lvl}.png")
save(battery(10, charging=True), "batt_chg.png")


def wifi(bars, w=50, h=34):
    im = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(im)
    for i in range(5):
        x = 2 + i * 9
        bh = 8 + i * 6
        y0 = h - 2 - bh
        if i < bars:
            d.rectangle([x, y0, x + 6, h - 2], fill=0)
        else:
            d.rectangle([x, y0, x + 6, h - 2], outline=0, width=1)
    return im


for bars in range(6):
    save(wifi(bars), f"wifi_{bars}.png")

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
