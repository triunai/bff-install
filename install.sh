#!/bin/sh
# bff installer for macOS and Linux (POSIX sh). Public; it downloads the bff release from the private
# triunai/bff repository through the GitHub CLI (gh), verifies SHA256SUMS, installs under ~/.local (no sudo)
# and runs `bff osiris setup`.
#   curl -fsSL https://raw.githubusercontent.com/triunai/bff-install/main/install.sh | sh
# Options (after `sh -s --` when piped): --yes  --no-setup  --no-modify-path  --prefix DIR  --help
# Env: BFF_VERSION=x.y.z installs that release instead of the latest.
# Every command that could read stdin gets </dev/null or </dev/tty: when this script is piped, stdin IS the script.
set -eu

main() {
  BFF_REPO=triunai/bff
  BFF_YES=0
  BFF_SETUP=1
  BFF_NO_PATH=0
  BFF_PREFIX=
  while [ $# -gt 0 ]; do
    case $1 in
      --yes|-y) BFF_YES=1 ;;
      --no-setup) BFF_SETUP=0 ;;
      --no-modify-path) BFF_NO_PATH=1 ;;
      --prefix)
        [ $# -ge 2 ] || { echo '--prefix needs a directory.' >&2; exit 2; }
        BFF_PREFIX=$2; shift ;;
      --help|-h)
        echo 'bff installer. Options: --yes  --no-setup  --no-modify-path  --prefix DIR  --help'
        echo 'Env: BFF_VERSION=x.y.z installs that release instead of the latest.'
        exit 0 ;;
      *) echo "Unknown option: $1 (try --help)." >&2; exit 2 ;;
    esac
    shift
  done

  # Questions go to the terminal, never to the pipe. No terminal and no --yes means no questions at all.
  BFF_TTY=0
  if [ "$BFF_YES" = 0 ] && (: </dev/tty) 2>/dev/null; then BFF_TTY=1; fi

  PYTHON_HELP='bff needs Python 3.9 or newer. Install it from https://www.python.org/downloads/ (or with your package manager), then run this installer again.'
  command -v python3 >/dev/null 2>&1 || { echo "$PYTHON_HELP" >&2; exit 1; }
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' </dev/null || { echo "$PYTHON_HELP" >&2; exit 1; }

  if ! command -v gh >/dev/null 2>&1; then
    cat >&2 <<MSG
bff lives in a private repository, so this installer needs the GitHub CLI (gh).
Install it:
  macOS:          brew install gh
  Debian/Ubuntu:  https://github.com/cli/cli/blob/trunk/docs/install_linux.md
  other:          https://cli.github.com
Then run:  gh auth login   (the account needs read access to $BFF_REPO)
and run this installer again.
MSG
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1 </dev/null; then
    echo "The GitHub CLI is not signed in. Run: gh auth login   (the account needs read access to $BFF_REPO), then run this installer again." >&2
    exit 1
  fi

  BFF_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/bff-install.XXXXXXXX")
  trap 'rm -rf "$BFF_STAGE"' EXIT HUP INT TERM

  BFF_FAIL="Download failed. Check that this gh account can read $BFF_REPO (gh release list --repo $BFF_REPO) and that a release is published, then run this installer again."
  if [ -n "${BFF_VERSION:-}" ]; then
    case $BFF_VERSION in
      *[!0-9.]*|''|.*|*.) echo 'BFF_VERSION must look like 1.2.3.' >&2; exit 2 ;;
    esac
    gh release download "v$BFF_VERSION" --repo "$BFF_REPO" --pattern 'bff-*.tar.gz' --pattern SHA256SUMS --dir "$BFF_STAGE" --clobber </dev/null >&2 || { echo "$BFF_FAIL" >&2; exit 1; }
  else
    gh release download --repo "$BFF_REPO" --pattern 'bff-*.tar.gz' --pattern SHA256SUMS --dir "$BFF_STAGE" --clobber </dev/null >&2 || { echo "$BFF_FAIL" >&2; exit 1; }
  fi

  # Exactly one bff-<version>.tar.gz; the version comes from its name and is checked before it is used.
  BFF_ARCHIVE=
  BFF_COUNT=0
  for f in "$BFF_STAGE"/bff-*.tar.gz; do
    [ -f "$f" ] || continue
    BFF_ARCHIVE=$f
    BFF_COUNT=$((BFF_COUNT + 1))
  done
  [ "$BFF_COUNT" = 1 ] || { echo "Expected one bff release archive, found $BFF_COUNT. $BFF_FAIL" >&2; exit 1; }
  BFF_NAME=${BFF_ARCHIVE##*/}
  BFF_VER=${BFF_NAME#bff-}
  BFF_VER=${BFF_VER%.tar.gz}
  case $BFF_VER in
    *[!0-9.]*|''|.*|*.) echo "Unexpected release archive name: $BFF_NAME" >&2; exit 1 ;;
  esac
  [ -f "$BFF_STAGE/SHA256SUMS" ] || { echo "The release has no SHA256SUMS file; refusing to install an unverified archive." >&2; exit 1; }
  mv "$BFF_ARCHIVE" "$BFF_STAGE/release.tar.gz"

  # Verify the checksum, bound the archive, refuse unsafe entries, then extract (stdlib only).
  python3 - "$BFF_STAGE" "$BFF_VER" <<'PY' || exit 1
import hashlib, pathlib, sys, tarfile
stage, version = pathlib.Path(sys.argv[1]), sys.argv[2]
archive = stage / 'release.tar.gz'
rows = [r.split() for r in (stage / 'SHA256SUMS').read_text().splitlines() if r.strip()]
expected = [r[0] for r in rows if len(r) == 2 and r[1] == 'bff-' + version + '.tar.gz']
if len(expected) != 1 or hashlib.sha256(archive.read_bytes()).hexdigest() != expected[0]:
    raise SystemExit('BFF archive checksum mismatch; installation stopped. Run the installer again; if it keeps failing, download it by hand from https://github.com/triunai/bff/releases.')
root = 'bff-' + version
with tarfile.open(archive, 'r:gz') as tf:
    members = tf.getmembers()
    if len(members) > 5000 or sum(m.size for m in members) > 100 * 1024 * 1024:
        raise SystemExit('BFF archive exceeds bounded release limits. This should not happen with an official release; download it by hand from https://github.com/triunai/bff/releases.')
    seen = set()
    for m in members:
        path = pathlib.PurePosixPath(m.name)
        if (path.is_absolute() or '..' in path.parts or not path.parts or
                path.parts[0] != root or not (m.isfile() or m.isdir()) or
                m.name != path.as_posix() or path.as_posix() in seen):
            raise SystemExit('BFF archive contains an unsafe entry. This should not happen with an official release; download it by hand from https://github.com/triunai/bff/releases.')
        seen.add(path.as_posix())
    for m in members:
        target = stage / m.name
        if m.isdir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tf.extractfile(m).read())
            target.chmod(0o755 if m.name.endswith('/install.sh') else 0o644)
PY
  BFF_INSTALLER=$BFF_STAGE/bff-$BFF_VER/install.py
  [ -f "$BFF_INSTALLER" ] || { echo 'The release has no install.py; refusing to continue.' >&2; exit 1; }

  # install.py offers the PATH edit once, and only when its stdin is a terminal.
  set -- "$BFF_INSTALLER"
  [ -z "$BFF_PREFIX" ] || set -- "$@" --prefix "$BFF_PREFIX"
  if [ "$BFF_YES" = 1 ]; then set -- "$@" --yes; fi
  if [ "$BFF_NO_PATH" = 1 ]; then set -- "$@" --no-modify-path; fi
  if [ "$BFF_TTY" = 1 ]; then
    BFF_RESULT=$(python3 "$@" </dev/tty) || exit $?
  else
    BFF_RESULT=$(python3 "$@" </dev/null) || exit $?
  fi
  printf '%s\n' "$BFF_RESULT"
  BFF_COMMAND=$(printf '%s' "$BFF_RESULT" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("command", ""))')
  [ -n "$BFF_COMMAND" ] || { echo 'Could not find the bff command after installing. Run this installer again.' >&2; exit 2; }
  echo "bff $BFF_VER installed: $BFF_COMMAND" >&2

  [ "$BFF_SETUP" = 1 ] || { echo 'Skipped Osiris setup (--no-setup). Later: bff osiris setup' >&2; return 0; }
  BFF_RC=0
  if [ "$BFF_YES" = 1 ]; then
    "$BFF_COMMAND" osiris setup --yes </dev/null || BFF_RC=$?
  elif [ "$BFF_TTY" = 1 ]; then
    "$BFF_COMMAND" osiris setup </dev/tty || BFF_RC=$?
  else
    echo 'No terminal to ask questions on, so Osiris setup was skipped. Later, in a terminal: bff osiris setup' >&2
    return 0
  fi
  if [ "$BFF_RC" = 3 ]; then echo 'bff is installed; Osiris setup is waiting on the prerequisites listed above. Install them, then run: bff osiris setup' >&2; return 0; fi
  if [ "$BFF_RC" = 4 ]; then echo 'bff is installed. Osiris is not publicly released yet, so there is nothing more to set up; run: bff --help' >&2; return 0; fi
  return "$BFF_RC"
}

main "$@"
