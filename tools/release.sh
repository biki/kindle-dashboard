#!/bin/sh
# Publishes the current kindle/kindledash folder to GitHub, so the Kindle installs it over Wi-Fi
# at its next update check (within UPDATE_EVERY minutes, or at once after a power-button press).
#
#   sh tools/release.sh "Commit message"
#
# Steps: syntax check, MANIFEST (md5 per file), commit, push.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MSG=${1:?usage: release.sh "commit message"}
cd "$ROOT"

for f in kindle/kindledash/*.sh kindle/documents/*.sh; do sh -n "$f"; done
if git ls-files -co --exclude-standard kindle/kindledash | grep -q 'secrets.conf'; then
    echo "secrets.conf is not ignored: stop" >&2; exit 1
fi

# MANIFEST: every file the Kindle needs (tracked or new, not ignored), "md5  path".
(
    cd kindle/kindledash
    git ls-files -co --exclude-standard . | grep -v '^MANIFEST$' | LC_ALL=C sort | while read -r f; do
        printf '%s  %s\n' "$(md5 -q "$f")" "$f"
    done
) > kindle/kindledash/MANIFEST
echo "MANIFEST: $(wc -l < kindle/kindledash/MANIFEST | tr -d ' ') files"

git add -A
git commit -q -m "$MSG"
git push -q -u origin HEAD
echo "pushed $(git rev-parse --short HEAD). The Kindle installs it at its next update check."
