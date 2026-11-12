#!/bin/sh
# Stops the dashboard and gives the screen back to the Kindle home screen.
DIR=/mnt/us/kindledash
# Kill every running copy of loop.sh (and its touch watcher, a forked copy of it).
for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    grep -q 'kindledash/loop.sh' "$p/cmdline" 2>/dev/null && kill "${p#/proc/}"
done
rm -f "$DIR/pid" "$DIR/tap" "$DIR/tap.read"
killall -CONT cvm 2>/dev/null
lipc-set-prop com.lab126.cmd wirelessEnable 1
for a in /sys/class/rtc/rtc*/wakealarm; do echo 0 > "$a"; done 2>/dev/null
lipc-set-prop com.lab126.powerd preventScreenSaver 0
# Put the front light back to the level from before the dashboard (saved by loop.sh).
if [ -f "$DIR/fl.saved" ]; then
    fl=$(tr -cd 0-9 < "$DIR/fl.saved")
    [ -n "$fl" ] && lipc-set-prop com.lab126.powerd flIntensity "$fl"
    rm -f "$DIR/fl.saved"
fi
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home
