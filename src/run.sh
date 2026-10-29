#!/bin/sh
# calibre wireless launcher:  run.sh start|stop|status|run|ui|app
#
# Self-contained: uses the LuaJIT, luasocket, lfs and FBInk bundled under
# runtime/<abi>/ (taken from KOReader's release builds). Nothing else from
# KOReader is needed or touched.

HERE="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$HERE/pid"

# Kindle ABI: hard-float devices (FW 5.16.3+) have the armhf loader.
if [ -e /lib/ld-linux-armhf.so.3 ]; then ABI=kindlehf; else ABI=kindlepw2; fi
RT="$HERE/runtime/$ABI"
LUAJIT="$RT/bin/luajit"

# FBInk: our bundled copy is the full build from the jailbreak's kmc payload
# (images + TrueType). Fall back to other copies on the device if needed.
# (KOReader's own fbink is a reduced build without image support.)
FBINK=""
for f in "$RT/bin/fbink" /var/local/kmc/bin/fbink /mnt/us/libkh/bin/fbink /mnt/us/extensions/MRInstaller/bin/fbink /mnt/us/koreader/fbink; do
    [ -x "$f" ] && { FBINK="$f"; break; }
done

is_running() {
    [ -f "$PIDFILE" ] || return 1
    PID=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$PID" ] && [ -d "/proc/$PID" ] && grep -q companion.lua "/proc/$PID/cmdline" 2>/dev/null
}

# Is the on-screen app already running? (pattern written so grep's own
# command line does not match itself)
ui_running() {
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q 'lua/ui[.]lua' && return 0
    done
    return 1
}

lua_env() {
    export COMPANION_DIR="$HERE"
    export COMPANION_ABI="$ABI"
    export FBINK
    export LUA_PATH="$HERE/lua/?.lua;$HERE/lua/vendor/?.lua;;"
    export LUA_CPATH="$RT/lib/?.so;$RT/lib/socket/?.so;;"
    [ -x "$LUAJIT" ] || chmod +x "$LUAJIT" "$RT/bin/fbink" 2>/dev/null
    cd "$HERE" || exit 1
}

case "$1" in
    start)
        if is_running; then echo "already running (pid $PID)"; exit 0; fi
        rm -f "$HERE/stop" "$HERE/cmd.stop" "$HERE/cmd.forever"
        nohup "$0" run >/dev/null 2>>"$HERE/log.txt" &
        sleep 1
        if is_running; then echo "started (pid $PID)"; else echo "failed to start, see $HERE/log.txt"; exit 1; fi
        ;;
    stop)
        if is_running; then
            touch "$HERE/stop"
            kill "$PID" 2>/dev/null
            sleep 1
            lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
            rm -f "$PIDFILE"
            echo "stopped"
        else
            echo "not running"
        fi
        ;;
    status)
        if is_running; then echo "running (pid $PID)"; else echo "not running"; exit 1; fi
        ;;
    run)
        lua_env
        exec "$LUAJIT" "$HERE/lua/companion.lua"
        ;;
    ui)
        if ui_running; then echo "app already open"; exit 0; fi
        rm -f "$HERE/ui.quit"
        lua_env
        exec "$LUAJIT" "$HERE/lua/ui.lua"
        ;;
    app)
        # What the library tile / KUAL entry runs: ensure the daemon, show the app.
        if ui_running; then echo "app already open"; exit 0; fi
        is_running || "$0" start >/dev/null
        rm -f "$HERE/ui.quit"
        lua_env
        "$LUAJIT" "$HERE/lua/ui.lua"
        if [ -f "$HERE/cmd.stop" ] || grep -q '"status":"stopped"' "$HERE/state.json" 2>/dev/null; then
            "$0" stop >/dev/null 2>&1
        fi
        ;;
    env)
        lua_env; echo "ABI=$ABI"; echo "LUAJIT=$LUAJIT"; echo "FBINK=$FBINK"
        ;;
    *)
        echo "usage: $0 start|stop|status|run|ui|app|env"; exit 2
        ;;
esac
