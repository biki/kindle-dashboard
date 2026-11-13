#!/bin/sh
# Kindle dashboard: downloads the weather and calendars and draws the dashboard with FBInk, forever.
#
# Each cycle: Wi-Fi on -> download -> Wi-Fi off -> render.awk -> FBInk -> suspend to RAM with an
# RTC alarm until the next refresh. The e-ink keeps the image without power. The Kindle UI (cvm)
# is paused, so nothing draws over the dashboard.
#
# Controls:
#   power button   wakes the Kindle: front light on, refresh now, then IDLE seconds awake.
#                  The light goes off again before the Kindle sleeps.
#   double tap     (while awake, also during a refresh) stops the dashboard and goes Home
#   single tap     (while awake, with the meter set up) switches dashboard <-> power meter view
#
# Power meter (tibber.sh, when TIBBER_HOST is set): one reading at each refresh, and a daily row
# for the Google Sheet at PUSH_AT. For that row the Kindle wakes up, also in the night pause.

DIR=${DASH_DIR:-/mnt/us/kindledash}
. "$DIR/kindledash.conf"
# Personal settings (calendar links), only on the Kindle: never in the repo, never updated.
[ -f "$DIR/secrets.conf" ] && . "$DIR/secrets.conf"
FBINK=${FBINK:-/mnt/us/libkh/bin/fbink}
POWER_STATE=${POWER_STATE:-/sys/power/state}
RTC=${RTC:-/sys/class/rtc}
TMP=${DASH_TMP:-/tmp/kindledash}
# 1 while a cable is in (computer or wall charger: the Kindle shows no difference). See usb_on.
USB_FILE=${USB_FILE:-/sys/devices/system/wario_charger/wario_charger0/connected}
mkdir -p "$TMP"
# In USB drive mode /mnt/us can be gone: the stop must work from /tmp.
cp "$DIR/stop.sh" "$TMP/stop.sh" 2>/dev/null
# busybox awk may take only one -f: join the parts once.
cat "$DIR/fontdata.awk" "$DIR/common.awk" "$DIR/render.awk" > "$TMP/render.awk"
# The meter view is a separate file: an error in tibber.awk must not stop the dashboard.
cat "$TMP/render.awk" "$DIR/tibber.awk" > "$TMP/meterview.awk"
cat "$DIR/common.awk" "$DIR/ical.awk" > "$TMP/ical.awk"
{ cat "$DIR/common.awk"; printf '%s\n' 'BEGIN { cfd(fdiv(t, 86400)); printf "%02d.%02d.%04d\n", CD, CM, CY }'; } > "$TMP/dlabel.awk"

# Plain http on purpose: Open-Meteo allows it, and it avoids TLS problems on old firmware.
URL="http://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&timezone=auto&forecast_days=8&format=csv\
&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m\
&hourly=temperature_2m,weather_code,precipitation_probability,is_day\
&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset"

log() { echo "$(date -u '+%m-%d %H:%M:%S') $*"; }
wifi() { lipc-set-prop com.lab126.cmd wirelessEnable "$1" 2>/dev/null; }
light() {  # front light level (0 = off). powerd sets it; for 0 also the backlight driver, to be sure.
    [ "$FL_LEVEL" = 0 ] && [ "$1" != 0 ] && return
    lipc-set-prop com.lab126.powerd flIntensity "$1" 2>/dev/null
    if [ "$1" = 0 ]; then for b in /sys/class/backlight/*/brightness; do echo 0 > "$b"; done 2>/dev/null; fi
}
get() {  # get URL FILE
    curl -s -S -f -L -m 30 -o "$2" "$1" 2>> "$TMP/curl.err" && return 0
    case "$1" in http:*) wget -q -T 30 -O "$2" "$1" 2>/dev/null ;; *) return 1 ;; esac
}
meta() { o=$(sed -n 2p "$DIR/weather.csv" 2>/dev/null | cut -d, -f"$1"); echo "${o:-$2}"; }
local_now() { echo $(($(date +%s) + $(meta 4 0))); }
tibber_on() { [ -n "$TIBBER_HOST" ]; }
dlabel() { awk -v t="$1" -f "$TMP/dlabel.awk"; }  # local wall epoch -> dd.mm.yyyy

# Wi-Fi on, weather as soon as the network works (or give up after WIFI_WAIT), calendars, Wi-Fi off.
refresh() {
    wifi 1
    t0=$(date +%s); wok=0
    while :; do
        # Temp files next to the target: a mv from /tmp to the FAT partition warns about ownership.
        if get "$URL" "$DIR/.weather.new" && grep -q '^time' "$DIR/.weather.new"; then
            mv -f "$DIR/.weather.new" "$DIR/weather.csv"
            date +%s > "$DIR/wtime"; wok=1
            break
        fi
        [ $(($(date +%s) - t0)) -ge "$WIFI_WAIT" ] && break
        sleep 3
    done
    if [ "$wok" = 1 ] && [ -n "$CALENDARS" ] && [ $(($(date +%s) - cal_last)) -ge $((CAL_EVERY * 60)) ]; then
        calfail=0; n=0
        for u in $CALENDARS; do
            n=$((n + 1))
            case "$u" in webcal://*) u="https://${u#webcal://}" ;; esac
            if get "$u" "$DIR/.cal.new" && grep -q 'BEGIN:VCALENDAR' "$DIR/.cal.new"; then
                mv -f "$DIR/.cal.new" "$DIR/cal-$n.ics"
            else
                calfail=$((calfail + 1)); log "calendar $n: download failed: $(tail -n 1 "$TMP/curl.err" 2>/dev/null)"
            fi
        done
        cal_last=$(date +%s); cal_day=""  # parse again
    fi
    # New version on GitHub? Checked every UPDATE_EVERY minutes, and after every power-button press.
    updated=0
    if [ "$wok" = 1 ] && [ -n "$UPDATE_URL" ] && { [ "$woke" = 1 ] || [ $(($(date +%s) - upd_last)) -ge $((UPDATE_EVERY * 60)) ]; }; then
        upd_last=$(date +%s)
        sh "$DIR/update.sh"
        [ $? = 10 ] && updated=1
    fi
    # Power meter: the bridge is on the home network. The sheet rows (chart) once a day.
    if tibber_on; then
        sh "$DIR/tibber.sh" read
        if [ "$wok" = 1 ] && [ -n "$SHEET_URL" ] && [ "$days_day" != "$(($(local_now) / 86400))" ]; then
            sh "$DIR/tibber.sh" days && days_day=$(($(local_now) / 86400))
        fi
    fi
    [ "$WIFI_OFF" = 1 ] && wifi 0
    log "refresh: weather $wok, calendars failed $calfail, $(($(date +%s) - t0)) s, battery $(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)%"
}

# Expands the calendars into events.txt for today and the next 7 days (when needed).
parse_calendars() {
    ln=$(local_now); day=$((ln / 86400))
    [ "$day" = "$cal_day" ] && return
    cal_day=$day
    set -- "$DIR"/cal-*.ics
    if [ -n "$CALENDARS" ] && [ -f "$1" ]; then
        awk -v from=$((day * 86400)) -v to=$(((day + 8) * 86400)) -v off="$(meta 4 0)" -v ltz="$(meta 5)" \
            -f "$TMP/ical.awk" "$@" | sort -t'|' -k1,1n -k2,2n -k3,3n -u > "$DIR/events.txt"
    else
        : > "$DIR/events.txt"
    fi
    log "calendar: $(wc -l < "$DIR/events.txt") events"
}

render() {
    off=$(meta 4 0); ln=$(($(date +%s) + off))
    wt=""; [ -f "$DIR/wtime" ] && wt=$(($(cat "$DIR/wtime") + off))
    [ -f "$DIR/weather.csv" ] || : > "$DIR/weather.csv"
    batt=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    ncal=0; for u in $CALENDARS; do ncal=$((ncal + 1)); done
    set -- -v now="$ln" -v lang="$DASH_LANG" -v place="$PLACE" -v batt="$batt" -v wtime="$wt" \
        -v ncal="$ncal" -v calfail="$calfail" -v off="$off" -v pushat="$PUSH_AT" \
        -v tfile="$DIR/tibber.txt" -v bfile="$DIR/tibber.base" -v dfile="$DIR/tibber-days.txt"
    if tibber_on && [ "$VIEW" = tibber ]; then
        awk "$@" -v view=tibber -f "$TMP/meterview.awk" "$DIR/weather.csv" "$DIR/events.txt" > "$TMP/screen.txt" 2> "$TMP/awk.err" \
            && grep -q '^T|' "$TMP/screen.txt" && return 0
        log "meter view failed, drawing the dashboard: $(head -c 200 "$TMP/awk.err")"
    fi
    awk "$@" -v view=dash -f "$TMP/render.awk" "$DIR/weather.csv" "$DIR/events.txt" > "$TMP/screen.txt"
}

# Executes render.awk's commands (see the top of render.awk) with FBInk, then one full refresh.
draw() {
    t0=$(date +%s); nc=0; nf=0
    "$FBINK" -q -b -k
    while IFS='|' read -r kind a b c d e f g text; do
        nc=$((nc + 1))
        case "$kind" in
        T)  font=$a
            set -- -q -b -O
            [ "$g" = c ] && set -- "$@" -m
            [ "$f" != BLACK ] && set -- "$@" -C "$f"
            "$FBINK" "$@" -t "regular=$DIR/fonts/$font.ttf,px=$b,top=$e,left=$c,right=$d" -- "$text" || nf=$((nf + 1)) ;;
        I)  "$FBINK" -q -b -g "file=$DIR/$a,x=$b,y=$c" || nf=$((nf + 1)) ;;
        R)  "$FBINK" -q -b -B "$e" -k "top=$b,left=$a,width=$c,height=$d" || nf=$((nf + 1)) ;;
        esac
    done < "$TMP/screen.txt"
    # Full flashing refresh; wait (-w) until the panel is done, so a suspend can't cut it short.
    "$FBINK" -q -f -s -w
    log "drew $nc commands in $(($(date +%s) - t0)) s, $nf failed"
}

prompt() {  # gray bar with a message at the top of the screen (black text: white text did not show)
    "$FBINK" -q -b -B GRAYD -k "top=0,left=0,width=758,height=64"
    "$FBINK" -q -b -B BLACK -k "top=64,left=0,width=758,height=3"
    "$FBINK" -q -b -O -m -t "regular=$DIR/fonts/B.ttf,px=30,top=16" -- "$1"
    "$FBINK" -q -s "top=0,left=0,width=758,height=67"
}

bye() {  # called by the touch watcher on a double tap
    rm -f "$TMP/tap"  # no view switch for the first tap
    log "exit: double tap"
    [ "$DASH_LANG" = de ] && prompt "Dashboard wird beendet …" || prompt "Closing dashboard …"
    setsid sh "$TMP/stop.sh" > /dev/null 2>&1 < /dev/null &
    exit 0
}

# USB cable in? Only an explicit 1 counts: a missing or unreadable file means "no cable",
# so a wrong signal can never block the dashboard (and with it the Wi-Fi updates).
usb_on() { [ "$USB_STOP" = 1 ] && [ "$(cat "$USB_FILE" 2>/dev/null)" = 1 ]; }

# A computer can mount /mnt/us while the dashboard writes there, and the paused Kindle UI can't
# handle USB mode. So: stop at once, Kindle UI back. Called by the USB watcher.
usb_bye() {
    rm -f "$TMP/tap"
    log "exit: USB cable"
    [ "$DASH_LANG" = de ] && prompt "USB-Kabel: Dashboard wird beendet …" || prompt "USB cable: closing dashboard …"
    setsid sh "$TMP/stop.sh" > /dev/null 2>&1 < /dev/null &
    exit 0
}

# Checks the cable every second while the Kindle is awake (a plug-in also wakes it).
# Two reads in a row, so one odd value does not stop the dashboard.
watch_usb() {
    while :; do
        sleep 1
        usb_on && { sleep 1; usb_on && usb_bye; }
    done
}

# Next refresh in seconds: the next multiple of INTERVAL minutes, moved to NIGHT_END in the night.
next_wait() {
    awk -v now="$(local_now)" -v iv="$INTERVAL" -v a="$NIGHT_START" -v b="$NIGHT_END" 'BEGIN {
        step = iv * 60; n = (int(now / step) + 1) * step; h = int((n % 86400) / 3600)
        if (a != b && (a < b ? h >= a && h < b : h >= a || h < b)) {
            e = n - n % 86400 + b * 3600; if (e <= n) e += 86400; n = e
        }
        w = n - now + 20; print (w < 60 ? 60 : w) }'
}

# UTC epoch of the next daily meter row (PUSH_AT local time). 0 = no meter.
next_push() {
    tibber_on || { echo 0; return; }
    awk -v now="$(local_now)" -v off="$(meta 4 0)" -v at="$PUSH_AT" 'BEGIN {
        split(at, a, ":"); t = now - now % 86400 + a[1] * 3600 + a[2] * 60
        if (t <= now) t += 86400
        print t - off }'
}

# Daily meter row (tibber.sh push). Wi-Fi on for it, no drawing, the light stays as it is.
# The row date is the day of the planned time, also when a retry comes after midnight.
# Failed (bridge or sheet): again every 10 min for 1 h. Then the next night writes a two-day row.
do_push() {
    [ -n "$push_label" ] || { push_label=$(dlabel $((push_due + $(meta 4 0)))); push_plan=$push_due; }
    wifi 1; t0=$(date +%s)
    while :; do
        sh "$DIR/tibber.sh" push "$push_label"; rc=$?
        [ "$rc" != 2 ] && break
        [ $(($(date +%s) - t0)) -ge "$WIFI_WAIT" ] && break
        sleep 10
    done
    [ "$WIFI_OFF" = 1 ] && wifi 0
    if [ "$rc" = 2 ] && [ $(($(date +%s) - push_plan)) -lt 3600 ]; then
        push_due=$(($(date +%s) + 600)); log "meter: row $push_label failed, again in 10 min"
    else
        [ "$rc" = 2 ] && log "meter: row $push_label failed, the next row covers two days"
        push_label=""; push_due=$(next_push)
    fi
}

detect_touch() {
    [ -n "$TOUCH" ] && { echo "$TOUCH"; return; }
    e=$(awk '/^N: Name=/ { n = tolower($0) }
        /^H: Handlers=/ && n ~ /touch|cyttsp|zforce|_mt|elan|ft5|mxt|goodix|synaptics/ {
            if (match($0, /event[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit } }' /proc/bus/input/devices 2>/dev/null)
    echo "/dev/input/${e:-event1}"
}

# Exits on a double tap: two finger-down events (EV_KEY BTN_TOUCH = type 1, code 330, value 1)
# within about 2 s. Runs in the background, so it also works while the main loop downloads.
# A single tap (no second tap within 3 s) makes $TMP/switch: the main loop switches the view.
# Raw input_event = 16 bytes on this 32-bit Kindle; after od: sec sec usec usec type code value value.
watch_touch() {
    last=0
    while :; do
        set -- $(dd bs=16 count=1 2>/dev/null <&3 | od -An -t d2)
        [ $# -ge 7 ] || { sleep 1; continue; }
        [ "$5" = 1 ] && [ "$6" = 330 ] && [ "$7" = 1 ] || continue
        n=$(date +%s)
        if [ $((n - last)) -le 2 ]; then bye; fi
        last=$n
        if tibber_on; then
            echo "$n" > "$TMP/tap"
            ( sleep 3; [ "$(cat "$TMP/tap" 2>/dev/null)" = "$n" ] && : > "$TMP/switch" ) &
        fi
    done
}

# Logs power-key presses (EV_KEY KEY_POWER = type 1, code 116, value 1) from the power-button
# device on fd 4, so the log shows which early wakes came from the button.
watch_power() {
    while :; do
        set -- $(dd bs=16 count=1 2>/dev/null <&4 | od -An -t d2)
        [ $# -ge 7 ] || { sleep 1; continue; }
        [ "$5" = 1 ] && [ "$6" = 116 ] && [ "$7" = 1 ] && log "power key"
    done
}
detect_power() {
    e=$(awk '/^N: Name=/ { n = tolower($0) }
        /^H: Handlers=/ && n ~ /onkey|power/ {
            if (match($0, /event[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit } }' /proc/bus/input/devices 2>/dev/null)
    [ -n "$e" ] && echo "/dev/input/$e"
}

# Suspends until epoch $1 (RTC alarm) or the power button. Sets early=1 on a power-button wake.
# After 3 failed suspends in a row, stays awake for good (SLEEP=0).
suspend_until() {
    early=0
    left=$(($1 - $(date +%s)))
    [ "$left" -gt 10 ] || { sleep 1; return; }
    for a in "$RTC"/rtc*/wakealarm; do echo 0 > "$a" && echo "+$left" > "$a"; done 2>/dev/null
    sync
    t0=$(date +%s)
    if echo mem > "$POWER_STATE" 2>/dev/null && [ $(($(date +%s) - t0)) -ge 3 ]; then
        fails=0; now=$(date +%s)
        log "slept $((now - t0)) of $left s"
        # More than 60 s before the alarm counts as a power-button wake. (The RTC can fire some
        # seconds early; the power watcher logs key presses, to check this rule.)
        [ "$now" -lt $(($1 - 60)) ] && early=1
    else
        fails=$((fails + 1)); log "suspend failed ($fails)"
        [ "$fails" -ge 3 ] && { SLEEP=0; log "can't suspend: staying awake between refreshes"; }
    fi
}

# Test mode (tools/dev-render.sh): one download and render into $TMP/screen.txt, no drawing.
VIEW=$(cat "$DIR/view" 2>/dev/null); [ "$VIEW" = tibber ] || VIEW=dash
if [ -n "$DASH_RENDER_ONLY" ]; then
    cal_last=0; cal_day=""; calfail=0; days_day=""
    refresh; parse_calendars; render
    exit
fi

echo $$ > "$DIR/pid"
log "start:fbink $FBINK, place $PLACE, $(set -- $CALENDARS; echo $#) calendar(s)"
sleep 3  # let the scriptlet finish first

# No start with a cable in: the Kindle UI must stay free for USB mode.
if usb_on; then
    log "exit: USB cable at start (remove it, then start again)"
    [ "$DASH_LANG" = de ] && prompt "Erst USB-Kabel entfernen, dann starten" || prompt "Remove the USB cable, then start"
    rm -f "$DIR/pid"
    exit 0
fi

TOUCH=$(detect_touch)
# Pause the Kindle UI only when the tap-to-exit works; otherwise there would be no way back.
if [ -c "$TOUCH" ] && [ -r "$TOUCH" ] && exec 3< "$TOUCH"; then
    killall -STOP cvm 2>/dev/null
    watch_touch &
    log "touch: $TOUCH, Kindle UI paused"
else
    log "can't open touch device $TOUCH: Kindle UI left running, no tap-to-exit"
fi
POWER=$(detect_power)
if [ -n "$POWER" ] && [ -c "$POWER" ] && [ -r "$POWER" ] && exec 4< "$POWER"; then
    watch_power &
    log "power key: $POWER"
fi
if [ "$USB_STOP" = 1 ]; then
    watch_usb &
    log "usb: stop on cable ($USB_FILE: $(cat "$USB_FILE" 2>/dev/null || echo missing))"
fi
lipc-set-prop com.lab126.powerd preventScreenSaver 1
# Keep the user's front light level, so stop.sh can put it back.
[ -f "$DIR/fl.saved" ] || lipc-get-prop com.lab126.powerd flIntensity > "$DIR/fl.saved" 2>/dev/null
log "front light was $(cat "$DIR/fl.saved" 2>/dev/null), on-wake level $FL_LEVEL"
light "$FL_LEVEL"; lit=1

rm -f "$DIR/tap" "$DIR/tap.read"  # files of older versions
rm -f "$TMP/tap" "$TMP/switch"
# woke=1: after the first refresh, stay awake IDLE s with the light on, as after a power-button wake.
due=0; awake_until=0; woke=1; fails=0; cal_last=0; cal_day=""; calfail=0; upd_last=0; days_day=""
push_due=$(next_push); push_label=""
tibber_on && log "meter: $TIBBER_HOST, view $VIEW, sheet $([ -n "$SHEET_URL" ] && echo on || echo off)"
while :; do
    if [ "$push_due" -gt 0 ] && [ "$(date +%s)" -ge "$push_due" ]; then
        do_push
        log "meter: next row at $(dlabel $((push_due + $(meta 4 0)))) $PUSH_AT"
    fi
    if [ "$(date +%s)" -ge "$due" ]; then
        refresh
        if [ "$updated" = 1 ]; then  # start the new version (start.sh stops this one first)
            log "restarting with the new version"
            setsid sh "$DIR/start.sh" > /dev/null 2>&1 < /dev/null &
            exit 0
        fi
        parse_calendars
        render && draw
        if [ "$wok" = 1 ]; then due=$(($(date +%s) + $(next_wait))); else due=$(($(date +%s) + 300)); fi
        log "next refresh in $(((due - $(date +%s)) / 60)) min"
        # After a power-button wake, stay awake IDLE s from now, so there is time for a double tap.
        [ "$woke" = 1 ] && { awake_until=$(($(date +%s) + IDLE)); woke=0; }
        # The first refresh has the UTC offset (weather.csv): plan the daily row again with it.
        [ -z "$push_label" ] && push_due=$(next_push)
    fi

    # Single tap: the other view, from the saved data (no Wi-Fi). Then IDLE s more awake.
    if [ -f "$TMP/switch" ]; then
        rm -f "$TMP/switch"
        if [ "$VIEW" = tibber ]; then VIEW=dash; else VIEW=tibber; fi
        echo "$VIEW" > "$DIR/view"
        log "tap: view $VIEW"
        render && draw
        awake_until=$(($(date +%s) + IDLE))
    fi
    wake=$due; [ "$push_due" -gt 0 ] && [ "$push_due" -lt "$wake" ] && wake=$push_due
    # A tap in the last seconds: stay awake until its switch can come (3 s after the tap).
    tap=$(cat "$TMP/tap" 2>/dev/null)
    if [ -n "$tap" ] && [ $(($(date +%s) - tap)) -le 4 ] && [ "$awake_until" -lt $((tap + 5)) ]; then
        awake_until=$((tap + 5))
    fi

    if [ "$SLEEP" = 1 ] && [ "$(date +%s)" -ge "$awake_until" ]; then
        [ "$lit" = 1 ] && { light 0; lit=0; }
        suspend_until "$wake"
        rm -f "$TMP/tap" "$TMP/switch"  # a tap from before the sleep does not count
        # Power button: light on at once (the refresh takes a while), refresh, then IDLE s awake.
        [ "$early" = 1 ] && { light "$FL_LEVEL"; lit=1; due=0; woke=1; }
    elif [ "$SLEEP" != 1 ] && [ "$lit" = 1 ] && [ "$(date +%s)" -ge "$awake_until" ]; then
        light 0; lit=0; sleep 1
    else
        sleep 1
    fi
done
