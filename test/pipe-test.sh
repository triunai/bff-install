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

# 4. gh missing / not signed in / download failure each name the fix and exit non-zero.
ARGS='--yes --no-setup'
OUT=$(cat "$HERE/install.sh" | env HOME="$WORK/home" PATH="/usr/bin:/bin" sh -s -- $ARGS 2>&1) && bad 'missing gh succeeded' || case $OUT in *'brew install gh'*'gh auth login'*) ok 'missing gh prints the fix' ;; *) bad 'missing gh message'; echo "$OUT" ;; esac
OUT=$(run_piped FAKE_GH_AUTH=fail 2>&1) && bad 'signed-out gh succeeded' || case $OUT in *'gh auth login'*'triunai/bff'*) ok 'signed-out gh prints the fix' ;; *) bad 'auth message'; echo "$OUT" ;; esac
OUT=$(run_piped FAKE_GH_DOWNLOAD=fail 2>&1) && bad 'failed download succeeded' || case $OUT in *'Download failed'*) ok 'download failure names the action' ;; *) bad 'download message'; echo "$OUT" ;; esac

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
