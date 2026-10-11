#!/bin/sh
# shellcheck disable=SC2015  # A && B || C is the report style here
# Runs install.ps1 for real under pwsh from a locally built release (BFF_RELEASE_DIR): piped like irm | iex, a prefix
# holding a space, and a corrupted SHA256SUMS. Needs pwsh and a bff checkout:  BFF_SRC=/path/to/bff sh test/pwsh-test.sh
# Never touches the real HOME or PATH and never hits the network.
set -eu

command -v pwsh >/dev/null 2>&1 || { echo 'SKIP: pwsh not installed.'; exit 0; }
[ -n "${BFF_SRC:-}" ] && [ -f "$BFF_SRC/scripts/build-bff-release.py" ] || { echo 'SKIP: set BFF_SRC to a bff checkout.'; exit 0; }
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bff-pwsh-test.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
FAILS=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

python3 "$BFF_SRC/scripts/build-bff-release.py" --output "$WORK/release" >/dev/null
run() { # release dir, prefix
  BFF_RELEASE_DIR=$1 BFF_PREFIX=$2 BFF_YES=1 BFF_NO_SETUP=1 BFF_RESULT_FILE="$WORK/result.json" \
    pwsh -NoProfile -NonInteractive -Command "Get-Content -Raw -LiteralPath '$HERE/install.ps1' | Invoke-Expression"
}

PREFIX="$WORK/pre fix"
OUT=$(run "$WORK/release" "$PREFIX" 2>&1) && ok 'piped install from a local release dir exits 0' || { bad 'install failed'; echo "$OUT"; }
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/result.json" && ok 'result is JSON' || bad 'result not JSON'
if [ -x "$PREFIX/bin/bff" ]; then "$PREFIX/bin/bff" --version | grep -q '^bff ' && ok 'installed bff runs' || bad 'bff --version failed'; else bad 'no command under the prefix'; fi

cp -R "$WORK/release" "$WORK/bad"
sed 's/^./0/' "$WORK/bad/SHA256SUMS" >"$WORK/bad/SHA256SUMS.new" && mv "$WORK/bad/SHA256SUMS.new" "$WORK/bad/SHA256SUMS"
OUT=$(run "$WORK/bad" "$WORK/never" 2>&1) && bad 'corrupt SHA256SUMS installed' || case $OUT in *'checksum mismatch'*) ok 'corrupt SHA256SUMS refused' ;; *) bad 'checksum message'; echo "$OUT" ;; esac
[ ! -e "$WORK/never" ] && ok 'nothing installed from the corrupt release' || bad 'corrupt release left files'

if [ "$FAILS" = 0 ]; then echo 'pwsh-test: all passed'; else echo "pwsh-test: $FAILS failed"; exit 1; fi
