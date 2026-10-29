#!/bin/sh
# KPM install hook for calibre wireless. Runs inside the unpacked package dir.
# $1 = "upgrade" when KPM is upgrading an existing install.

set -e
DEST=/mnt/us/calibre-wireless
PAYLOAD=./payload

if [ ! -d "$PAYLOAD" ]; then echo "payload missing"; exit 1; fi

# Keep the user's settings and the device book list across upgrades.
KEEP=/mnt/us/calibre-wireless.keep
rm -rf "$KEEP"; mkdir -p "$KEEP"
for f in config.lua books.json driveinfo.json; do
    [ -f "$DEST/$f" ] && cp -f "$DEST/$f" "$KEEP/$f"
done

# Stop a running companion (and close its on-screen app) before replacing files.
[ -x "$DEST/run.sh" ] && "$DEST/run.sh" stop >/dev/null 2>&1 || true
for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q 'lua/ui[.]lua' && kill "${p#/proc/}" 2>/dev/null
done
killall -CONT awesome >/dev/null 2>&1 || true
lipc-set-prop com.lab126.pillow disableEnablePillow enable >/dev/null 2>&1 || true

rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$PAYLOAD"/. "$DEST"/
for f in "$KEEP"/*; do [ -f "$f" ] && cp -f "$f" "$DEST/"; done
rm -rf "$KEEP"

chmod +x "$DEST/run.sh" "$DEST"/runtime/*/bin/* 2>/dev/null || true
chmod 755 "$DEST"/runtime/*/lib/*.so "$DEST"/runtime/*/lib/socket/*.so 2>/dev/null || true

# Library tile (scriptlet). The scanner picks up the Icon: header.
cp -f "$DEST/scriptlets/calibre wireless.sh" "/mnt/us/documents/calibre wireless.sh"
chmod +x "/mnt/us/documents/calibre wireless.sh"

# KUAL menu entry, if KUAL is present.
if [ -d /mnt/us/extensions ]; then
    rm -rf /mnt/us/extensions/calibrewireless
    cp -r "$DEST/kual/calibrewireless" /mnt/us/extensions/calibrewireless
fi

echo "calibre wireless installed to $DEST"
echo "Tap 'calibre wireless' in your library to connect."
exit 0
