#!/bin/sh
# shellcheck disable=SC2015,SC2086  # A && B || C is the report style here; $ARGS is a deliberate word list
# Pipe test for install.sh: `cat install.sh | sh` with a fake gh, a locally built release and a temp HOME.
# Needs a bff source checkout to build the release from:  BFF_SRC=/path/to/bff sh test/pipe-test.sh
# Never touches the real HOME or PATH, never hits the network, never needs sudo.
set -eu

[ -n "${BFF_SRC:-}" ] && [ -f "$BFF_SRC/scripts/build-bff-release.py" ] || { echo 'SKIP: set BFF_SRC to a bff checkout (needs scripts/build-bff-release.py).'; exit 0; }
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bff-pipe-test.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
FAILS=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

python3 "$BFF_SRC/scripts/build-bff-release.py" --output "$WORK/release" >/dev/null
mkdir -p "$WORK/fakebin" "$WORK/home"
cat >"$WORK/fakebin/gh" <<'GH'
#!/bin/sh
# Fake gh: `auth status` and `release download ... --dir DIR`, served from $FAKE_RELEASE.
case "$1 $2" in
  "auth status") [ "${FAKE_GH_AUTH:-ok}" = ok ] || { echo 'not logged in' >&2; exit 1; }; exit 0 ;;
  "release download")
    dir=
    while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done
    [ -n "$dir" ] || exit 2
    [ "${FAKE_GH_DOWNLOAD:-ok}" = ok ] || { echo 'HTTP 404' >&2; exit 1; }
    cp "$FAKE_RELEASE/bff-"*.tar.gz "$FAKE_RELEASE/SHA256SUMS" "$dir/"
    exit 0 ;;
esac
echo "fake gh: unexpected $*" >&2
exit 2
GH
chmod +x "$WORK/fakebin/gh"
cat >"$WORK/fakebin/curl" <<'CURL'
#!/bin/sh
# Fake curl: `curl ... -o DEST URL` serves URL's file name from $FAKE_RELEASE; records the URL in $FAKE_CURL_LOG.
dest=; url=
while [ $# -gt 0 ]; do
  case $1 in -o) dest=$2; shift ;; -*) ;; *) url=$1 ;; esac
  shift
done
echo "$url" >>"${FAKE_CURL_LOG:-/dev/null}"
[ "${FAKE_CURL_FAIL:-0}" = 0 ] || { echo 'curl: (22) 404' >&2; exit 22; }
cp "$FAKE_RELEASE/${url##*/}" "$dest"
CURL
chmod +x "$WORK/fakebin/curl"
SAFE_PATH="$WORK/fakebin:/usr/bin:/bin"   # no bb, no brew: `bff osiris setup` can only report prerequisites

run_piped() { # args to install.sh; stdin is the script, like curl | sh
  cat "$HERE/install.sh" | env HOME="$WORK/home" PATH="$SAFE_PATH" FAKE_RELEASE="$WORK/release" "$@" sh -s -- $ARGS
}

# 1. fresh install through the pipe, --yes answers every question, setup runs and reports prerequisites.
ARGS='--yes'
OUT=$(run_piped 2>&1) && RC=0 || RC=$?
[ "$RC" = 0 ] && ok 'piped install exits 0' || { bad "piped install exit $RC"; echo "$OUT"; }
[ -L "$WORK/home/.local/bin/bff" ] && ok 'command symlink created under the temp HOME' || bad 'no ~/.local/bin/bff'
"$WORK/home/.local/bin/bff" --version | grep -q '^bff ' && ok 'installed bff runs' || bad 'bff --version failed'
case $OUT in *'waiting on the prerequisites'*) ok 'setup ran and reported prerequisites' ;; *) bad 'setup output missing'; echo "$OUT" ;; esac
[ -z "$(ls -d "${TMPDIR:-/tmp}"/bff-install.* 2>/dev/null)" ] && ok 'temp dir cleaned' || bad 'temp dir left behind'

# 2. idempotent: second run, same release, still exit 0.
OUT=$(run_piped 2>&1) && ok 'second run is idempotent' || { bad 'second run failed'; echo "$OUT"; }

# 3. no PATH edit under --yes; startup files untouched.
[ -z "$(find "$WORK/home" -maxdepth 1 -name '.*profile' -o -maxdepth 1 -name '.bashrc' 2>/dev/null)" ] && ok 'no shell startup file edited under --yes' || bad 'startup file edited'

# 4. The repository is public: no gh, or a signed-out gh, falls back to plain HTTPS downloads of the release assets.
ARGS='--yes --no-setup'
NOGH="$WORK/nogh"; mkdir -p "$NOGH"; cp "$WORK/fakebin/curl" "$NOGH/curl"; NOGH_PATH="$NOGH:/usr/bin:/bin"
rm -f "$WORK/curl.log"
OUT=$(cat "$HERE/install.sh" | env HOME="$WORK/home3" PATH="$NOGH_PATH" FAKE_RELEASE="$WORK/release" FAKE_CURL_LOG="$WORK/curl.log" sh -s -- $ARGS 2>&1) && ok 'no gh installs over plain HTTPS' || { bad 'no-gh install failed'; echo "$OUT"; }
grep -q '^https://github.com/triunai/bff/releases/latest/download/SHA256SUMS$' "$WORK/curl.log" && grep -q '^https://github.com/triunai/bff/releases/latest/download/bff-.*\.tar\.gz$' "$WORK/curl.log" && ok 'latest assets requested from the public release URL' || { bad 'download URLs'; cat "$WORK/curl.log"; }
rm -f "$WORK/curl.log"
OUT=$(cat "$HERE/install.sh" | env HOME="$WORK/home3" PATH="$NOGH_PATH" BFF_VERSION=9.9.9 FAKE_RELEASE="$WORK/release" FAKE_CURL_LOG="$WORK/curl.log" sh -s -- $ARGS 2>&1) || true
grep -q '^https://github.com/triunai/bff/releases/download/v9.9.9/SHA256SUMS$' "$WORK/curl.log" && ok 'a pinned version uses its tag URL' || { bad 'versioned URL'; cat "$WORK/curl.log"; }
OUT=$(run_piped FAKE_GH_AUTH=fail FAKE_CURL_LOG="$WORK/curl2.log" 2>&1) && [ -s "$WORK/curl2.log" ] && ok 'signed-out gh falls back to HTTPS' || { bad 'signed-out gh did not fall back'; echo "$OUT"; }
OUT=$(cat "$HERE/install.sh" | env HOME="$WORK/home3" PATH="/usr/bin:/bin" BFF_DOWNLOAD=gh sh -s -- $ARGS 2>&1) && bad 'BFF_DOWNLOAD=gh without gh succeeded' || case $OUT in *'needs the GitHub CLI'*) ok 'BFF_DOWNLOAD=gh without gh names the fix' ;; *) bad 'gh message'; echo "$OUT" ;; esac
OUT=$(run_piped FAKE_GH_DOWNLOAD=fail 2>&1) && bad 'failed gh download succeeded' || case $OUT in *'Download failed'*) ok 'gh download failure names the action' ;; *) bad 'download message'; echo "$OUT" ;; esac
OUT=$(cat "$HERE/install.sh" | env HOME="$WORK/home3" PATH="$NOGH_PATH" FAKE_RELEASE="$WORK/release" FAKE_CURL_FAIL=1 sh -s -- $ARGS 2>&1) && bad 'failed HTTPS download succeeded' || case $OUT in *'Download failed'*) ok 'HTTPS download failure names the action' ;; *) bad 'https message'; echo "$OUT" ;; esac

# 5. a corrupted archive is refused by the checksum.
cp -R "$WORK/release" "$WORK/bad"
for f in "$WORK"/bad/bff-*.tar.gz; do printf 'x' >>"$f"; done
OUT=$(cat "$HERE/install.sh" | env HOME="$WORK/home2" PATH="$SAFE_PATH" FAKE_RELEASE="$WORK/bad" sh -s -- --yes --no-setup 2>&1) && bad 'corrupt archive installed' || case $OUT in *'checksum mismatch'*) ok 'corrupt archive refused' ;; *) bad 'checksum message'; echo "$OUT" ;; esac
[ ! -e "$WORK/home2/.local/bin/bff" ] && ok 'nothing installed from the corrupt archive' || bad 'corrupt archive left a command'

# 6. no terminal and no --yes: no questions, setup skipped with the later command.
ARGS=''
OUT=$(run_piped 2>&1 </dev/null) && RC=0 || RC=$?
case $OUT in *'bff osiris setup'*) ok 'headless run skips questions and says how to run setup' ;; *) bad 'headless message'; echo "$OUT" ;; esac

[ "$FAILS" = 0 ] && echo 'ALL PASSED' || { echo "$FAILS FAILED"; exit 1; }
