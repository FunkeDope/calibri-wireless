"""Pull the Kindle artwork that assets/src/make_assets.py renders with.

python tools/fetch_device_art.py <kindle-ip>   (KINDLE_PW env, user root)

Copies Amazon's Ember fonts to fonts/ and the status-bar SVG icons of the
5.17+ UI to icons/. Both are Amazon's and stay out of git (.gitignore); only
the PNGs rendered from them are committed.
"""
import os
import sys

import paramiko

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FONT_DIR = "/usr/java/lib/fonts"
FONTS = ["Amazon-Ember-Regular.ttf", "Amazon-Ember-Medium.ttf", "Amazon-Ember-Bold.ttf"]
ICON_DIR = "/app/KPPMainApp/res/KPPUIComponents/internal/icons"
ICONS = ["battery-default.svg", "battery-charging.svg", "wifi-offline.svg",
         "wifi-zero.svg", "wifi-one.svg", "wifi-two.svg", "wifi-three.svg"]


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    pw = os.environ.get("KINDLE_PW")
    if not pw:
        print("KINDLE_PW not set", file=sys.stderr)
        return 2
    t = paramiko.Transport((sys.argv[1], 22))
    t.connect(username="root", password=pw)
    try:
        sftp = paramiko.SFTPClient.from_transport(t)
        for sub, remote_dir, names in (("fonts", FONT_DIR, FONTS), ("icons", ICON_DIR, ICONS)):
            local_dir = os.path.join(ROOT, sub)
            os.makedirs(local_dir, exist_ok=True)
            for n in names:
                sftp.get(f"{remote_dir}/{n}", os.path.join(local_dir, n))
                print(f"{sub}/{n}")
    finally:
        t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
