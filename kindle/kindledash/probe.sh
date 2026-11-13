#!/bin/sh
# Records what this Kindle has (tools, screen, input devices, network) in probe.txt.
DIR=/mnt/us/kindledash
. "$DIR/kindledash.conf"
[ -f "$DIR/secrets.conf" ] && . "$DIR/secrets.conf"
FBINK=/mnt/us/libkh/bin/fbink
{
    echo "--- system"; id; uname -a; cat /etc/prettyversion.txt 2>/dev/null; date -u; echo "TZ=$TZ"
    echo "--- tools"
    for c in curl wget awk sort od dd md5sum setsid nohup killall lipc-set-prop lipc-get-prop; do
        printf '%s: ' "$c"; command -v "$c" || echo missing
    done
    busybox 2>&1 | head -1
    echo "--- fbink"; ls -l "$FBINK"  # "fbink -e" crashes (segfault) on FBInk 1.25.0 here
    echo "--- awk multiple -f"; echo 'BEGIN{print "one"}' > /tmp/kd1.awk; echo 'BEGIN{print "two"}' > /tmp/kd2.awk
    awk -f /tmp/kd1.awk -f /tmp/kd2.awk 2>&1
    echo "--- wifi"; lipc-get-prop com.lab126.wifid cmState; lipc-get-prop com.lab126.cmd wirelessEnable
    echo "--- battery"; lipc-get-prop com.lab126.powerd battLevel
    echo "--- front light"; lipc-get-prop com.lab126.powerd flIntensity
    for b in /sys/class/backlight/*; do echo "$b: $(cat "$b/brightness" 2>/dev/null) / $(cat "$b/max_brightness" 2>/dev/null)"; done
    echo "--- weather (http)"; curl -s -S -m 20 "http://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&timezone=auto&format=csv&current=temperature_2m" 2>&1 | head -5
    echo "--- update source"; curl -s -S -m 20 -o /dev/null -w '%{http_code}\n' "$UPDATE_URL/MANIFEST" 2>&1
    echo "--- https test"; curl -s -S -m 20 -o /dev/null -w '%{http_code}\n' https://calendar.google.com/ 2>&1
    for u in $CALENDARS; do
        case "$u" in webcal://*) u="https://${u#webcal://}" ;; esac
        echo "--- calendar: ${u%%\?*}"; curl -s -S -L -m 30 "$u" 2>&1 | head -3
    done
    if [ -n "$TIBBER_HOST" ]; then
        echo "--- meter bridge (http status, bytes)"
        curl -s -S -m 15 -u "$TIBBER_USER:$TIBBER_PASS" -o /tmp/kd-meter.bin -w '%{http_code} %{size_download}\n' \
            "http://$TIBBER_HOST$TIBBER_PATH" 2>&1
        echo "first bytes: $(od -An -N 16 -t x1 /tmp/kd-meter.bin 2>/dev/null)"
        r=$(od -An -v -t x1 /tmp/kd-meter.bin 2>/dev/null | awk -v mode=sml -f "$DIR/meter.awk")
        [ -n "$r" ] || r=$(tr -d '\000' < /tmp/kd-meter.bin 2>/dev/null | awk -v mode=text -f "$DIR/meter.awk")
        echo "decoded (total_kwh|power_w): ${r:-nothing}"
    fi
    if [ -n "$SHEET_URL" ]; then
        echo "--- sheet (newest 3 rows)"; curl -s -S -L -m 60 -d "token=$SHEET_TOKEN&action=rows&n=3" "$SHEET_URL" 2>&1 | head -n 4
    fi
    echo "--- input"; cat /proc/bus/input/devices
    echo "--- rtc"; ls /sys/class/rtc/
    echo "--- ui"; pidof cvm
} > "$DIR/probe.txt" 2>&1
echo "Probe done. Connect USB and read kindledash/probe.txt"
