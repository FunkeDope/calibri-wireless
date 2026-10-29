#!/bin/sh
# KPM uninstall hook for calibre wireless.
# $1 = "upgrade" when this removal is part of an upgrade (keep user data then).

DEST=/mnt/us/calibre-wireless

[ -x "$DEST/run.sh" ] && "$DEST/run.sh" stop >/dev/null 2>&1

# Only remove the scriptlet if it is ours.
S="/mnt/us/documents/calibre wireless.sh"
if [ -f "$S" ] && grep -q "calibre-wireless/run.sh" "$S" 2>/dev/null; then
    rm -f "$S"
    rm -rf "/mnt/us/documents/calibre wireless.sh.sdr"
fi
rm -rf /mnt/us/extensions/calibrewireless

if [ "$1" = "upgrade" ]; then
    echo "upgrade: keeping $DEST for the new version's install hook"
else
    rm -rf "$DEST" /mnt/us/.calibre_incoming
    echo "calibre wireless removed"
fi
exit 0
