"""Extract the Kindle runtime pieces from KOReader release zips.

calibre wireless runs on LuaJIT with luasocket and LuaFileSystem, draws with
FBInk, and parses JSON with dkjson (pure Lua). None of these are built here;
they are taken, unmodified, from KOReader's official release zips, which ship
them prebuilt for both Kindle ABIs:

    kindlehf   armhf (hard-float)  -- firmware 5.16.3+ devices
    kindlepw2  armel (soft-float)  -- Paperwhite 2 .. Oasis 1 era devices

Usage:
    python tools/fetch_runtime.py [--version v2026.07.1] [--dest runtime] [--download-dir C:/tmp/koreader-dl]

If the zips are not in --download-dir they are downloaded with `gh release download`.
"""
import argparse
import os
import shutil
import subprocess
import sys
import zipfile

ABIS = ("kindlehf", "kindlepw2")

# zip member -> destination relative to runtime/<abi>/
# (fbink is NOT taken from KOReader: its build lacks image support. The full
#  fbink builds come from the jailbreak's jb.sh payload, see extract_jb_fbink.py)
FILES = {
    "koreader/luajit": "bin/luajit",
    "koreader/common/socket/score.so": "lib/socket/score.so",
    "koreader/libs/libkoreader-lfs.so": "lib/lfs.so",   # luaopen_lfs symbol -> require("lfs")
}
# architecture-independent Lua, taken once
LUA_FILES = {
    "koreader/common/socket.lua": "socket.lua",
    "koreader/common/dkjson.lua": "dkjson.lua",
}
LICENSE_FILES = {
    "koreader/COPYING": "COPYING.koreader",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="v2026.07.1")
    ap.add_argument("--dest", default=os.path.join(os.path.dirname(__file__), "..", "runtime"))
    ap.add_argument("--lua-dest", default=os.path.join(os.path.dirname(__file__), "..", "src", "lua", "vendor"))
    ap.add_argument("--download-dir", default=os.path.join(os.environ.get("TEMP", "/tmp"), "koreader-dl"))
    args = ap.parse_args()
    os.makedirs(args.download_dir, exist_ok=True)

    for abi in ABIS:
        name = f"koreader-{abi}-{args.version}.zip"
        path = os.path.join(args.download_dir, name)
        if not os.path.exists(path):
            print("downloading", name)
            subprocess.check_call(["gh", "release", "download", args.version, "-R", "koreader/koreader",
                                   "-p", name, "-D", args.download_dir, "--clobber"])
        dest = os.path.abspath(os.path.join(args.dest, abi))
        with zipfile.ZipFile(path) as z:
            for member, rel in FILES.items():
                out = os.path.join(dest, rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with z.open(member) as src, open(out, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                print(f"{abi}: {member} -> {os.path.relpath(out)} ({os.path.getsize(out)} bytes)")
            if abi == ABIS[0]:
                for table, base in ((LUA_FILES, args.lua_dest), (LICENSE_FILES, os.path.join(args.dest, ".."))):
                    for member, rel in table.items():
                        out = os.path.abspath(os.path.join(base, rel))
                        os.makedirs(os.path.dirname(out), exist_ok=True)
                        with z.open(member) as src, open(out, "wb") as dst:
                            shutil.copyfileobj(src, dst)
                        print(f"common: {member} -> {os.path.relpath(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
