"""Build the KPM package for calibre wireless.

python tools/build.py            -> dist/calibre-wireless_<ver>_kindlehf-kindlepw2.kpkg
python tools/build.py --abi kindlehf   (single-ABI package)

A .kpkg is a gzip tarball with manifest.json, install.sh, uninstall.sh,
launch.sh, README.md and LICENSE at its root (what KPM expects) plus our
payload/ directory, which install.sh copies to /mnt/us/calibre-wireless.
Executable bits are set explicitly because this is usually built on Windows.
"""
import argparse
import io
import json
import os
import shutil
import sys
import tarfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
EXEC_SUFFIXES = (".sh",)
EXEC_NAMES = ("luajit", "fbink")


def add_tree(tar, src, arc):
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, src).replace("\\", "/")
            add_file(tar, full, f"{arc}/{rel}")


def add_file(tar, full, arcname):
    ti = tar.gettarinfo(full, arcname=arcname)
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(os.path.getmtime(full))
    base = os.path.basename(full)
    executable = base.endswith(EXEC_SUFFIXES) or base in EXEC_NAMES or base.endswith(".so")
    ti.mode = 0o755 if executable else 0o644
    with open(full, "rb") as f:
        tar.addfile(ti, f)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--abi", choices=["kindlehf", "kindlepw2", "all"], default="all")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist"))
    args = ap.parse_args()

    manifest = json.load(open(os.path.join(ROOT, "kpm", "manifest.json"), encoding="utf-8"))
    abis = ["kindlehf", "kindlepw2"] if args.abi == "all" else [args.abi]
    manifest["supported_platforms"] = abis
    ver = ".".join(str(v) for v in manifest["version"])
    name = f"{manifest['id']}_{ver}_{'-'.join(abis)}.kpkg"
    os.makedirs(args.out, exist_ok=True)
    out = os.path.join(args.out, name)

    for abi in abis:
        for rel in ("bin/luajit", "bin/fbink", "lib/lfs.so", "lib/socket/score.so"):
            p = os.path.join(ROOT, "runtime", abi, rel)
            if not os.path.exists(p):
                print(f"missing {p}; run tools/fetch_runtime.py first", file=sys.stderr)
                return 1

    with tarfile.open(out, "w:gz", compresslevel=6) as tar:
        # package root
        mbytes = json.dumps(manifest, indent=2).encode("utf-8")
        ti = tarfile.TarInfo("manifest.json"); ti.size = len(mbytes); ti.mode = 0o644; ti.mtime = int(time.time())
        tar.addfile(ti, io.BytesIO(mbytes))
        for f in ("install.sh", "uninstall.sh", "launch.sh"):
            add_file(tar, os.path.join(ROOT, "kpm", f), f)
        add_file(tar, os.path.join(ROOT, "README.md"), "README.md")
        add_file(tar, os.path.join(ROOT, "LICENSE"), "LICENSE")
        add_file(tar, os.path.join(ROOT, "THIRD_PARTY.md"), "THIRD_PARTY.md")
        # payload -> /mnt/us/calibre-wireless
        add_file(tar, os.path.join(ROOT, "src", "run.sh"), "payload/run.sh")
        add_file(tar, os.path.join(ROOT, "src", "config.lua"), "payload/config.lua")
        add_tree(tar, os.path.join(ROOT, "src", "lua"), "payload/lua")
        add_tree(tar, os.path.join(ROOT, "src", "scriptlets"), "payload/scriptlets")
        add_tree(tar, os.path.join(ROOT, "src", "kual"), "payload/kual")
        add_tree(tar, os.path.join(ROOT, "assets"), "payload/assets")
        for abi in abis:
            add_tree(tar, os.path.join(ROOT, "runtime", abi), f"payload/runtime/{abi}")
        add_file(tar, os.path.join(ROOT, "COPYING.koreader"), "payload/COPYING.koreader")
    print("wrote", os.path.relpath(out, ROOT), os.path.getsize(out), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
