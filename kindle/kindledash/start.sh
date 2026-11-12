#!/bin/sh
DIR=/mnt/us/kindledash
sh "$DIR/stop.sh" >/dev/null 2>&1
# Keep the log short: about one line per refresh. Read it over USB to debug.
[ -f "$DIR/loop.log" ] && tail -n 400 "$DIR/loop.log" > "$DIR/loop.log.tmp" && mv -f "$DIR/loop.log.tmp" "$DIR/loop.log"
# Detach from the scriptlet runner, so the loop keeps running after the scriptlet ends.
if command -v setsid >/dev/null 2>&1; then
    setsid nohup sh "$DIR/loop.sh" >> "$DIR/loop.log" 2>&1 < /dev/null &
else
    nohup sh "$DIR/loop.sh" >> "$DIR/loop.log" 2>&1 < /dev/null &
fi
