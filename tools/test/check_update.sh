#!/bin/sh
# Tests kindle/kindledash/update.sh in busybox (Docker). A busybox httpd plays GitHub.
#   sh tools/test/check_update.sh
# Cases: no change -> 0; valid update -> 10 and files replaced; broken render.awk -> 1, old kept;
# wrong checksum -> 1, old kept; secrets.conf never touched.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/remote" "$W/dev" "$W/bin"
cp -R "$ROOT/kindle/kindledash/." "$W/remote/"
cat > "$W/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -m|-w) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
wget -q -O "$out" "$url"
EOF
chmod +x "$W/bin/curl"

cat > "$W/run.sh" <<'EOF'
set -u
cd /w
mf() { (cd remote && find . -type f ! -name MANIFEST | sed 's|^\./||' | sort | while read -r f; do echo "$(md5sum "$f" | cut -d' ' -f1)  $f"; done) > remote/MANIFEST; }
sed -i 's|^UPDATE_URL=.*|UPDATE_URL="http://127.0.0.1:8000"|' remote/kindledash.conf
mf
cp -R remote/. dev/
echo 'CALENDARS="secret"' > dev/secrets.conf
httpd -p 8000 -h /w/remote
run() { PATH=/w/bin:$PATH DASH_DIR=/w/dev DASH_TMP=/tmp/kd sh /w/dev/update.sh > /tmp/out 2>&1; rc=$?; cat /tmp/out | sed 's/^/    /'; echo "$rc"; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1 (exit $2)"; else echo "FAIL $1: exit $2, expected $3"; FAILED=1; fi; }
FAILED=0

rc=$(run | tail -1); check "no change" "$rc" 0

echo '# changed' >> remote/render.awk; mf
rc=$(run | tail -1); check "valid update" "$rc" 10
cmp -s remote/render.awk dev/render.awk && echo "ok   render.awk replaced" || { echo "FAIL render.awk not replaced"; FAILED=1; }
cmp -s remote/MANIFEST dev/MANIFEST && echo "ok   MANIFEST replaced" || { echo "FAIL MANIFEST not replaced"; FAILED=1; }

cp dev/render.awk /tmp/good.awk
echo 'END { this is not awk (' >> remote/render.awk; mf
out=$(run); rc=$(echo "$out" | tail -1); check "broken render.awk" "$rc" 1
echo "$out" | grep -q 'test render failed' && echo "ok   reason logged" || { echo "FAIL reason: $out"; FAILED=1; }
cmp -s /tmp/good.awk dev/render.awk && echo "ok   old render.awk kept" || { echo "FAIL old render.awk lost"; FAILED=1; }

cp /tmp/good.awk remote/render.awk; echo '# v3' >> remote/common.awk; mf
sed -i 's/^\([0-9a-f]*\)  common.awk$/00000000000000000000000000000000  common.awk/' remote/MANIFEST
rc=$(run | tail -1); check "wrong checksum" "$rc" 1

[ "$(cat dev/secrets.conf)" = 'CALENDARS="secret"' ] && echo "ok   secrets.conf untouched" || { echo "FAIL secrets.conf changed"; FAILED=1; }
[ -d dev/.update ] && { echo "FAIL .update left behind"; FAILED=1; } || echo "ok   no .update left behind"
exit $FAILED
EOF
docker run --rm -v "$W:/w" "${BUSYBOX:-busybox:1.36}" sh /w/run.sh
