#!/bin/sh
# Power meter (Tibber Pulse Bridge) and the daily Google Sheet row. loop.sh calls this while
# Wi-Fi is on. Replaces the old Raspberry Pi (biki/pizero). Settings: kindledash.conf, secrets.conf.
#
#   tibber.sh read         one reading -> tibber.txt "utc_epoch|total_kwh|power_w"
#   tibber.sh push DATE    daily row for DATE (dd.mm.yyyy): consumption since the last row
#   tibber.sh days         newest sheet rows -> tibber-days.txt "dd.mm.yyyy|total|daily"
#
# Exit status: 0 = done (or nothing to do), 1 = refused (do not retry today), 2 = try again later.
#
# Daily row = meter counter now - counter at the last row (tibber.base "date|total_kwh"). The
# baseline moves only after the sheet confirmed the row, so a failed night becomes a two-day row.
# No baseline on the Kindle (first run): the newest sheet row is the baseline.

DIR=${DASH_DIR:-/mnt/us/kindledash}
. "$DIR/kindledash.conf"
[ -f "$DIR/secrets.conf" ] && . "$DIR/secrets.conf"
TMP=${DASH_TMP:-/tmp/kindledash}
mkdir -p "$TMP"
[ -n "$TIBBER_HOST" ] || exit 0

say() { echo "$(date -u '+%m-%d %H:%M:%S') meter: $*"; }
# Temp files next to the target: a mv from /tmp to the FAT partition warns about ownership.
put() { cat > "$DIR/.$1.new" && mv -f "$DIR/.$1.new" "$DIR/$1"; }

fetch() {  # fetch FILE: one payload from the bridge
    curl -s -S -f -m 15 -u "$TIBBER_USER:$TIBBER_PASS" -o "$1" "http://$TIBBER_HOST$TIBBER_PATH" 2>> "$TMP/curl.err"
}
decode() {  # decode FILE -> "total_kwh|power_w", or nothing
    r=$(od -An -v -t x1 "$1" | awk -v mode=sml -f "$DIR/meter.awk")
    [ -n "$r" ] || r=$(tr -d '\000' < "$1" | awk -v mode=text -f "$DIR/meter.awk")
    echo "$r"
}
# One reading into R ("total|power"). Logs the reason on failure.
reading() {
    R=""
    if ! fetch "$TMP/meter.bin"; then
        say "bridge not reachable: $(tail -n 1 "$TMP/curl.err" 2>/dev/null)"; return 2
    fi
    R=$(decode "$TMP/meter.bin")
    [ -n "$R" ] && return 0
    say "no 1.8.0 in the bridge data ($(wc -c < "$TMP/meter.bin") bytes, starts $(od -An -N 8 -t x1 "$TMP/meter.bin" | tr -d ' '))"
    return 2
}

# POST to the Apps Script web app: sheet OUT field=value... The answer goes to OUT.
# curl follows Google's redirect with a GET, which is what Apps Script expects.
sheet() {
    o=$1; shift
    d="token=$SHEET_TOKEN"; for kv in "$@"; do d="$d&$kv"; done
    curl -s -S -f -L -m 60 -d "$d" -o "$o" "$SHEET_URL" 2>> "$TMP/curl.err" || { say "sheet not reachable: $(tail -n 1 "$TMP/curl.err" 2>/dev/null)"; return 2; }
    case "$(head -n 1 "$o")" in ok* | dup*) return 0 ;; esac
    say "sheet answered: $(head -n 1 "$o" | cut -c1-120)"; return 2
}

# Newest N rows of the sheet -> tibber-days.txt.
days() {
    [ -n "$SHEET_URL" ] || return 0
    sheet "$TMP/rows" action=rows "n=${1:-70}" || return 2
    sed 1d "$TMP/rows" | grep '^[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9][0-9][0-9]|' | put tibber-days.txt
    say "sheet: $(wc -l < "$DIR/tibber-days.txt") rows"
}

case "$1" in
read)
    reading || exit 2
    echo "$(date +%s)|$R" | put tibber.txt
    say "read ${R%%|*} kWh, ${R#*|} W"
    ;;

days) days || exit 2 ;;

push)
    label=$2
    case "$label" in [0-9][0-9].[0-9][0-9].[0-9][0-9][0-9][0-9]) ;; *) say "push: bad date $label"; exit 1 ;; esac
    # Two readings 5 s apart must agree: the awk decoder has no CRC check.
    reading || exit 2; r1=$R
    sleep 5
    reading || exit 2; r2=$R
    total=${r2%%|*}
    ok=$(awk -v a="${r1%%|*}" -v b="$total" 'BEGIN { print (b >= a && b - a < 0.5) ? 1 : 0 }')
    [ "$ok" = 1 ] || { say "push: readings disagree (${r1%%|*}, $total kWh)"; exit 2; }
    echo "$(date +%s)|$r2" | put tibber.txt

    bdate=""; base=""
    [ -f "$DIR/tibber.base" ] && IFS='|' read -r bdate base < "$DIR/tibber.base"
    src="Kindle"
    if [ -z "$base" ] && [ -n "$SHEET_URL" ]; then
        sheet "$TMP/rows" action=rows n=1 || exit 2
        sed -n 2p "$TMP/rows" > "$TMP/newest"
        IFS='|' read -r bdate base x < "$TMP/newest"; src="sheet"
    fi
    if [ -z "$base" ]; then  # nothing to compare with: keep the counter, the first row comes tomorrow
        echo "$label|$total" | put tibber.base
        say "push: no baseline yet, saved $total kWh, no row"; exit 0
    fi
    [ "$bdate" = "$label" ] && { say "push: row $label exists already"; exit 0; }

    # Days between the baseline and this row (more than 1 after missed nights).
    n=$(awk -v a="$bdate" -v b="$label" 'function z(s,   y, m, d) {
            d = substr(s, 1, 2) + 0; m = substr(s, 4, 2) + 0; y = substr(s, 7, 4) + 0
            if (m <= 2) { y--; m += 12 }
            return int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + d }
        BEGIN { k = z(b) - z(a); print k < 1 ? 1 : k }')
    daily=$(awk -v t="$total" -v b="$base" 'BEGIN { printf "%.2f", t - b }')
    verdict=$(awk -v d="$daily" -v n="$n" -v mx="$DAY_MAX_KWH" 'BEGIN { print d < 0 ? "neg" : (d > mx * n ? "big" : "ok") }')
    case "$verdict" in
    neg)  # meter swap or a bad reading: a row would break the series
        say "push: counter went back ($base -> $total kWh), no row"
        echo "$label|$total" | put tibber.base; exit 1 ;;
    big)
        say "push: $daily kWh in $n day(s) is more than DAY_MAX_KWH, no row"; exit 1 ;;
    esac
    say "push: $label $daily kWh (baseline $base from $src, $bdate)"

    if [ -n "$SHEET_URL" ]; then
        sheet "$TMP/push" action=push "date=$label" "total=$total" "daily=$daily" || exit 2
        say "push: sheet $(head -n 1 "$TMP/push")"
        echo "$label|$total" | put tibber.base
        days || true
    else  # no sheet: keep the rows on the Kindle only, for the chart
        echo "$label|$total" | put tibber.base
        { echo "$label|$total|$daily"; head -n 69 "$DIR/tibber-days.txt" 2>/dev/null; } > "$TMP/days"
        put tibber-days.txt < "$TMP/days"
    fi
    ;;

*) echo "usage: tibber.sh read | push dd.mm.yyyy | days" >&2; exit 1 ;;
esac
exit 0
