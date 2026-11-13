#!/bin/sh
# Tests kindle/kindledash/tibber.sh in busybox (Docker). A busybox httpd plays the Tibber bridge
# (synthetic SML frames) and the Apps Script web app (a CGI with the answers of tools/sheet/Code.gs).
#   sh tools/test/check_tibber.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/dev" "$W/bin" "$W/www/cgi-bin" "$W/p"
cp -R "$ROOT/kindle/kindledash/." "$W/dev/"

# Meter payloads (kWh): start, +12.53, +12.53 +9.9, backwards, far too high
uv run -q --project "$ROOT/tools" python - "$W/p" "$ROOT/tools/test" <<'EOF'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
from tibber_fixtures import build_sml
out = Path(sys.argv[1])
for name, kwh in {"start": 18000.0, "day1": 18012.53, "day2": 18022.43, "back": 17000.0, "huge": 18900.0}.items():
    (out / f"{name}.bin").write_bytes(build_sml(kwh * 1000, 512))
EOF

# curl stub: busybox wget. Keeps -d as a POST body.
cat > "$W/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""; data=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -d) data=$2; shift 2 ;; -m|-w|-u) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
if [ -n "$data" ]; then wget -q -O "$out" --post-data "$data" "$url"; else wget -q -O "$out" "$url"; fi
EOF
# Apps Script stand-in. Rows newest first in /w/sheet.txt: "dd.mm.yyyy|total|daily".
cat > "$W/www/cgi-bin/sheet" <<'EOF'
#!/bin/sh
body=$(head -c "${CONTENT_LENGTH:-0}")
get() { echo "$body" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
echo "Content-Type: text/plain"; echo
[ "$(get token)" = "t0ken" ] || { echo "error|bad token"; exit 0; }
R=/w/sheet.txt; touch $R
case "$(get action)" in
rows) echo ok; head -n "$(get n)" $R ;;
push)
    d=$(get date)
    if [ "$(head -n 1 $R | cut -d'|' -f1)" = "$d" ]; then echo "dup|$d"
    else { echo "$d|$(get total)|$(get daily)"; cat $R; } > $R.new; mv $R.new $R; echo "ok|row 2"; fi ;;
*) echo "error|unknown action" ;;
esac
EOF
chmod +x "$W/bin/curl" "$W/www/cgi-bin/sheet"

cat > "$W/run.sh" <<'EOF'
cd /w
cat >> dev/secrets.conf <<'X'
TIBBER_HOST="127.0.0.1:8090"
TIBBER_PASS="x"
SHEET_URL="http://127.0.0.1:8090/cgi-bin/sheet"
SHEET_TOKEN="t0ken"
X
httpd -p 8090 -h /w/www
FAILED=0
meter() { cp "p/$1.bin" www/node_data.json; }
t() { PATH=/w/bin:$PATH DASH_DIR=/w/dev DASH_TMP=/tmp/kd sh /w/dev/tibber.sh "$@" > /tmp/out 2>&1; rc=$?; sed 's/^/    /' /tmp/out; }
is() {  # is NAME ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; FAILED=1; fi
}

meter start; t read
is "read: exit" "$rc" 0
is "read: tibber.txt" "$(cut -d'|' -f2- dev/tibber.txt)" "18000.0000|512"

t push 12.11.2026
is "first push, empty sheet: exit" "$rc" 0
is "first push: baseline saved" "$(cat dev/tibber.base)" "12.11.2026|18000.0000"
is "first push: no row" "$(wc -l < sheet.txt | tr -d ' ')" 0

meter day1; t push 13.11.2026
is "push: exit" "$rc" 0
is "push: sheet row" "$(head -n 1 sheet.txt)" "13.11.2026|18012.5300|12.53"
is "push: baseline moved" "$(cat dev/tibber.base)" "13.11.2026|18012.5300"
is "push: chart rows" "$(head -n 1 dev/tibber-days.txt)" "13.11.2026|18012.5300|12.53"

t push 13.11.2026
is "same day again: exit" "$rc" 0
is "same day again: no new row" "$(wc -l < sheet.txt | tr -d ' ')" 1

rm dev/tibber.base; meter day2; t push 14.11.2026
is "no local baseline: exit" "$rc" 0
is "no local baseline: row from the sheet's newest total" "$(head -n 1 sheet.txt)" "14.11.2026|18022.4300|9.90"
grep -q "baseline 18012.5300 from sheet" /tmp/out && echo "ok   baseline source logged" || { echo "FAIL baseline source"; FAILED=1; }

echo '15.11.2026|1|1' > /tmp/x; cat /tmp/x sheet.txt > /tmp/y; cp /tmp/y sheet.txt   # the Pi wrote 15.11 already
t push 15.11.2026
is "sheet has the date (dup): exit" "$rc" 0
is "dup: no new row" "$(sed -n 2p sheet.txt)" "14.11.2026|18022.4300|9.90"
is "dup: baseline moved" "$(cat dev/tibber.base)" "15.11.2026|18022.4300"

meter back; t push 16.11.2026
is "counter went back: exit" "$rc" 1
is "counter went back: baseline reset" "$(cat dev/tibber.base)" "16.11.2026|17000.0000"
is "counter went back: no row" "$(head -n 1 sheet.txt | cut -d'|' -f1)" "15.11.2026"

echo "16.11.2026|18022.4300" > dev/tibber.base; meter huge; t push 17.11.2026
is "more than DAY_MAX_KWH: exit" "$rc" 1
is "too high: baseline kept" "$(cat dev/tibber.base)" "16.11.2026|18022.4300"

rm www/node_data.json; t push 17.11.2026
is "bridge down: exit" "$rc" 2
is "bridge down: baseline kept" "$(cat dev/tibber.base)" "16.11.2026|18022.4300"

meter day2; sed -i 's/^SHEET_TOKEN=.*/SHEET_TOKEN="wrong"/' dev/secrets.conf
cp p/day2.bin www/node_data.json; echo "16.11.2026|18012.5300" > dev/tibber.base; t push 17.11.2026
is "sheet refuses (bad token): exit" "$rc" 2
is "sheet refuses: baseline kept" "$(cat dev/tibber.base)" "16.11.2026|18012.5300"
grep -q "bad token" /tmp/out && echo "ok   sheet error logged" || { echo "FAIL sheet error not logged"; FAILED=1; }

t push 2026-11-17
is "bad date: exit" "$rc" 1

# Without a sheet: rows only on the Kindle
sed -i 's/^SHEET_URL=.*/SHEET_URL=""/' dev/secrets.conf
meter day2; echo "16.11.2026|18012.5300" > dev/tibber.base; t push 17.11.2026
is "no sheet: exit" "$rc" 0
is "no sheet: local row" "$(head -n 1 dev/tibber-days.txt)" "17.11.2026|18022.4300|9.90"

# Meter off (no TIBBER_HOST): nothing happens
sed -i 's/^TIBBER_HOST=.*/TIBBER_HOST=""/' dev/secrets.conf; rm -f dev/tibber.txt
t read
is "meter off: exit" "$rc" 0
[ -f dev/tibber.txt ] && { echo "FAIL meter off wrote tibber.txt"; FAILED=1; } || echo "ok   meter off: no files"
exit $FAILED
EOF
docker run --rm -v "$W:/w" "${BUSYBOX:-busybox:1.36}" sh /w/run.sh
