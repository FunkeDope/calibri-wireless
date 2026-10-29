"""Capture README screenshots from a Kindle, rendered from a placeholder state.

python tools/qc_shots.py <host> [--geom STRIDE WxH] [--out screenshots]

Uploads a hand-written state file (calibre "my-pc" at 192.168.1.20, connected
a moment ago, 3 h left), opens the app on each screen with UI_STATE_FILE /
UI_START_SCREEN, dumps /dev/fb0, downloads and converts it. The daemon does
not need to run. Closes the app and hands the screen back when done.
Password from KINDLE_PW; user root. Default geometry is the Paperwhite 5.
"""
import json
import os
import sys
import time

import paramiko
from PIL import Image

REMOTE = "/mnt/us/calibre-wireless"
SCREENS = [("main", "app-connected.png"), ("choose", "app-choose.png"), ("keypad", "app-keypad.png")]
KILL_UI = ("for p in /proc/[0-9]*; do tr '\\0' ' ' < $p/cmdline 2>/dev/null | grep -q 'lua/ui[.]lua' "
           "&& kill ${p#/proc/}; done; sleep 1; killall -CONT awesome >/dev/null 2>&1; "
           "lipc-set-prop com.lab126.pillow disableEnablePillow enable >/dev/null 2>&1")


def placeholder_state():
    now = int(time.time())
    return {
        "status": "connected",
        "candidates": [{"host": "192.168.1.20", "port": 9090, "name": "my-pc"}],
        "host": "192.168.1.20", "port": 9090, "calibre_name": "my-pc",
        "started_at": now - 20, "deadline": now + 3 * 3600 - 20, "forever": False,
        "last_book": None, "received_count": 0, "this_book": None, "total_books": None,
        "pid_alive": True, "updated": now,
    }


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    host = sys.argv[1]
    stride, w, h = 1248, 1236, 1648
    if "--geom" in sys.argv:
        i = sys.argv.index("--geom")
        stride = int(sys.argv[i + 1])
        w, h = (int(v) for v in sys.argv[i + 2].lower().split("x"))
    out_dir = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "screenshots"
    pw = os.environ.get("KINDLE_PW")
    if not pw:
        print("KINDLE_PW not set", file=sys.stderr)
        return 2
    os.makedirs(out_dir, exist_ok=True)

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, username="root", password=pw, timeout=15, look_for_keys=False, allow_agent=False)
    sftp = client.open_sftp()

    def run(cmd, timeout=60):
        _, out, err = client.exec_command(cmd, timeout=timeout)
        return out.read().decode(errors="replace") + err.read().decode(errors="replace")

    try:
        run(KILL_UI)
        with sftp.open(f"{REMOTE}/qc_state.json", "w") as f:
            f.write(json.dumps(placeholder_state()))
        for screen, name in SCREENS:
            run(f"cd {REMOTE} && rm -f ui.quit && (UI_STATE_FILE={REMOTE}/qc_state.json UI_START_SCREEN={screen} "
                f"nohup ./run.sh ui >/dev/null 2>&1 &)")
            time.sleep(7)
            run(f"cat /dev/fb0 > {REMOTE}/fb.raw")
            raw = f"{REMOTE}/fb.raw"
            local_raw = os.path.join(out_dir, f".{screen}.raw")
            sftp.get(raw, local_raw)
            data = open(local_raw, "rb").read()
            rows = min(h, len(data) // stride)
            im = Image.frombytes("L", (stride, rows), data[: stride * rows]).crop((0, 0, w, rows))
            im = im.resize((w // 2, rows // 2), Image.LANCZOS)
            im.save(os.path.join(out_dir, name), optimize=True)
            os.remove(local_raw)
            print("wrote", os.path.join(out_dir, name), im.size)
            run(KILL_UI)
        run(f"rm -f {REMOTE}/qc_state.json {REMOTE}/fb.raw")
    finally:
        sftp.close()
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
