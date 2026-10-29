"""Pull the full FBInk builds (both Kindle ABIs) out of KindleModding's jb.sh.

jb.sh is a self-contained jailbreak script that embeds its "kmc" payload as a
base64-encoded xz tarball on one line (`echo "<base64>" | base64 -d | xz -d | tar ...`).
The payload has kindlehf/bin/fbink and kindlepw2/bin/fbink: full FBInk builds
with image + TrueType support (the KOReader copy is a reduced build without
image support). FBInk is GPL-3.0; source: https://github.com/NiLuJe/FBInk and
the jb.sh build in https://github.com/KindleModding/jb.sh.

python tools/extract_jb_fbink.py <path/to/jb.sh> [--dest runtime]
"""
import argparse
import base64
import io
import lzma
import os
import re
import sys
import tarfile

ap = argparse.ArgumentParser()
ap.add_argument("jbsh")
ap.add_argument("--dest", default=os.path.join(os.path.dirname(__file__), "..", "runtime"))
args = ap.parse_args()

blob = None
with open(args.jbsh, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        m = re.match(r'\s*echo\s+"([A-Za-z0-9+/=]{1000,})"', line)
        if m:
            blob = m.group(1)
            break
if not blob:
    print("no embedded payload found", file=sys.stderr)
    sys.exit(1)

raw = lzma.decompress(base64.b64decode(blob))
tar = tarfile.open(fileobj=io.BytesIO(raw))
names = tar.getnames()
print("payload entries:", len(names))
found = 0
for member in tar.getmembers():
    m = re.search(r"(kindlehf|kindlepw2)/bin/fbink$", member.name.replace("\\", "/"))
    if m and member.isfile():
        abi = m.group(1)
        out = os.path.abspath(os.path.join(args.dest, abi, "bin", "fbink"))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with tar.extractfile(member) as src, open(out, "wb") as dst:
            dst.write(src.read())
        print(f"{member.name} -> {os.path.relpath(out)} ({os.path.getsize(out)} bytes)")
        found += 1
if found < 2:
    print("fbink entries seen:", [n for n in names if n.endswith("fbink")], file=sys.stderr)
    sys.exit(2)
