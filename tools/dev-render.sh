#!/bin/sh
# Runs the real kindle/kindledash/loop.sh once (DASH_RENDER_ONLY) in busybox (Docker), with stub
# lipc-* and curl commands, then draws the result with tools/preview.py.
#
#   sh tools/dev-render.sh out.png [calendar.ics] [en|de] [dash|tibber]
#
# The weather is downloaded for real. The calendar is a local file (default: tools/test/cases.ics).
# tibber: a busybox httpd plays the Tibber bridge with a synthetic SML frame, and the sheet rows
# are synthetic too (tools/test/tibber_fixtures.py). loop.sh reads the meter as on the Kindle.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: dev-render.sh out.png [calendar.ics] [en|de]}
ICS=${2:-$ROOT/tools/test/cases.ics}
LANG_=${3:-en}
VIEW=${4:-dash}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp -R "$ROOT/kindle/kindledash" "$WORK/ext"
cp "$ICS" "$WORK/cal.ics"
sed -i.bak -e 's|^CALENDARS=.*|CALENDARS="file:///work/cal.ics"|' -e "s|^DASH_LANG=.*|DASH_LANG=$LANG_|" -e "s|^UPDATE_URL=.*|UPDATE_URL=\"\"|" "$WORK/ext/kindledash.conf"
mkdir -p "$WORK/bin" "$WORK/meter"
if [ "$VIEW" = tibber ]; then
    uv run -q --project "$ROOT/tools" python "$ROOT/tools/test/tibber_fixtures.py" preview "$WORK/meter"
    cp "$WORK/meter/tibber-days.txt" "$WORK/meter/tibber.base" "$WORK/ext/"
    echo tibber > "$WORK/ext/view"
    sed -i.bak -e 's|^TIBBER_HOST=.*|TIBBER_HOST="127.0.0.1:8081"|' "$WORK/ext/kindledash.conf"
fi
cat > "$WORK/bin/lipc-get-prop" <<'EOF'
#!/bin/sh
echo 87
EOF
cat > "$WORK/bin/lipc-set-prop" <<'EOF'
#!/bin/sh
exit 0
EOF
# curl stub: file:// -> cp, http -> busybox wget. Last two args of loop.sh's get(): -o FILE URL
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -m|-w|-u|-d) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
case "$url" in file://*) cp "${url#file://}" "$out" ;; *) wget -q -O "$out" "$url" ;; esac
EOF
chmod +x "$WORK/bin/"*

docker run --rm -v "$WORK:/work" -w /work "${BUSYBOX:-busybox:1.36}" sh -c \
    'httpd -p 8081 -h /work/meter; PATH=/work/bin:$PATH DASH_DIR=/work/ext DASH_TMP=/work/tmp DASH_RENDER_ONLY=1 sh /work/ext/loop.sh'
echo "events:"; sed 's/^/  /' "$WORK/ext/events.txt"
uv run -q --project "$ROOT/tools" python "$ROOT/tools/preview.py" "$OUT" < "$WORK/tmp/screen.txt"
cp "$WORK/tmp/screen.txt" "${OUT%.png}.txt"
echo "wrote $OUT and ${OUT%.png}.txt"
