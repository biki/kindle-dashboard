#!/bin/sh
# Pulls a new version of the dashboard over Wi-Fi from UPDATE_URL (the raw GitHub folder).
#
# MANIFEST lists "md5  path" for every file. Only changed files are downloaded, into .update/,
# and checked (MD5, shell syntax, one test render) before they replace the running ones.
# secrets.conf and the files the dashboard writes are never touched.
#
# Exit status: 0 = no change, 10 = updated (restart the loop), 1 = error (old version kept).

DIR=${DASH_DIR:-/mnt/us/kindledash}
. "$DIR/kindledash.conf"
[ -f "$DIR/secrets.conf" ] && . "$DIR/secrets.conf"
[ -n "$UPDATE_URL" ] || exit 0
ST="$DIR/.update"
TMP=${DASH_TMP:-/tmp/kindledash}
mkdir -p "$TMP"

say() { echo "$(date -u '+%m-%d %H:%M:%S') update: $*"; }
fail() { say "$*, keeping the current version"; rm -rf "$ST"; exit 1; }
get() { curl -s -S -f -L -m 60 -o "$2" "$1" 2>> "$TMP/curl.err"; }
sum() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

rm -rf "$ST"; mkdir -p "$ST"
get "$UPDATE_URL/MANIFEST" "$ST/MANIFEST" || fail "manifest download failed"
grep -q '  loop.sh$' "$ST/MANIFEST" && grep -q '  render.awk$' "$ST/MANIFEST" || fail "manifest looks wrong"
if cmp -s "$ST/MANIFEST" "$DIR/MANIFEST"; then rm -rf "$ST"; exit 0; fi

# Download the files whose checksum differs.
n=0
while read -r want path; do
    case "$path" in "" | /* | *..* | secrets.conf) fail "bad path in manifest: $path" ;; esac
    [ -f "$DIR/$path" ] && [ "$(sum "$DIR/$path")" = "$want" ] && continue
    mkdir -p "$ST/$(dirname "$path")"
    get "$UPDATE_URL/$path" "$ST/$path" || fail "download failed: $path"
    [ "$(sum "$ST/$path")" = "$want" ] || fail "checksum mismatch: $path (GitHub cache? next try later)"
    n=$((n + 1))
done < "$ST/MANIFEST"

# Checks: shell syntax, and one render with the new awk files on the current data.
for f in "$ST"/*.sh; do
    [ -f "$f" ] || continue
    sh -n "$f" 2>/dev/null || fail "syntax error in ${f##*/}"
done
pick() { if [ -f "$ST/$1" ]; then echo "$ST/$1"; else echo "$DIR/$1"; fi; }
cat "$(pick fontdata.awk)" "$(pick common.awk)" "$(pick render.awk)" > "$TMP/render-test.awk" || fail "can't assemble render.awk"
[ -f "$DIR/weather.csv" ] || : > "$DIR/weather.csv"
[ -f "$DIR/events.txt" ] || : > "$DIR/events.txt"
awk -v now="$(date +%s)" -v lang=de -v place=Test -v batt=50 -v wtime="" -v ncal=1 -v calfail=0 \
    -f "$TMP/render-test.awk" "$DIR/weather.csv" "$DIR/events.txt" > "$TMP/render-test.txt" 2>&1 \
    || fail "test render failed: $(head -c 200 "$TMP/render-test.txt")"
grep -q '^T|' "$TMP/render-test.txt" || fail "test render drew no text"
# The power meter view (tibber.awk after render.awk), with no meter data, and the SML decoder.
if [ -f "$(pick tibber.awk)" ]; then
    cat "$TMP/render-test.awk" "$(pick tibber.awk)" > "$TMP/render-test2.awk"
    awk -v now="$(date +%s)" -v lang=de -v place=Test -v batt=50 -v wtime="" -v ncal=1 -v calfail=0 \
        -v view=tibber -v off=0 -v pushat=23:55 -v tfile=/nonexistent -v bfile=/nonexistent -v dfile=/nonexistent \
        -f "$TMP/render-test2.awk" "$DIR/weather.csv" "$DIR/events.txt" > "$TMP/render-test.txt" 2>&1 \
        || fail "test render (meter) failed: $(head -c 200 "$TMP/render-test.txt")"
    grep -q '^T|' "$TMP/render-test.txt" || fail "test render (meter) drew no text"
fi
if [ -f "$(pick meter.awk)" ]; then
    r=$(echo "77 07 01 00 01 08 00 ff 01 01 62 1e 52 ff 65 00 b3 b0 4e 01" | awk -v mode=sml -f "$(pick meter.awk)" 2>&1)
    [ "$r" = "1177.6078|" ] || fail "meter.awk test failed: $r"
fi
cat "$(pick common.awk)" "$(pick ical.awk)" > "$TMP/ical-test.awk"
echo "BEGIN:VCALENDAR" | awk -v from=0 -v to=86400 -v off=0 -v ltz=UTC -f "$TMP/ical-test.awk" > /dev/null 2>&1 \
    || fail "ical.awk does not parse"

# Apply: copy each file next to its target and rename it (a new file, so a running script that
# still reads the old one is not disturbed).
while read -r want path; do
    [ -f "$ST/$path" ] || continue
    mkdir -p "$DIR/$(dirname "$path")"
    cp "$ST/$path" "$DIR/$path.new" && mv -f "$DIR/$path.new" "$DIR/$path" || fail "can't write $path"
done < "$ST/MANIFEST"
# Remove fonts and icons that the new version no longer has.
for f in "$DIR"/fonts/* "$DIR"/icons/*; do
    [ -f "$f" ] || continue
    grep -q "  ${f#$DIR/}\$" "$ST/MANIFEST" || rm -f "$f"
done
cp "$ST/MANIFEST" "$DIR/MANIFEST"
rm -rf "$ST"
say "installed $n changed file(s), version $(sum "$DIR/MANIFEST" | cut -c1-8)"
exit 10
