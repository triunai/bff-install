#!/bin/sh
# Self-check: this repository is public, so it must hold no personal paths, emails, tokens or internal names.
# Usage: sh check.sh   (exit 0 clean, 1 on any hit). Also runs sh -n and, when installed, shellcheck.
set -eu
cd "$(dirname "$0")"
FAILS=0
FILES=$(git ls-files 2>/dev/null || find . -type f -not -path './.git/*' | sed 's|^\./||')
# check.sh itself holds the patterns, so it is not scanned.
FILES=$(printf '%s\n' "$FILES" | grep -vx 'check.sh' || true)

hit() { # description, extended regex
  found=$(printf '%s\n' "$FILES" | while IFS= read -r f; do [ -f "$f" ] && grep -nEI -e "$2" "$f" /dev/null || true; done)
  if [ -n "$found" ]; then echo "FAIL: $1"; echo "$found"; FAILS=$((FAILS + 1)); fi
}

hit 'personal home paths' '/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9_][A-Za-z0-9._-]*|[A-Za-z]:\\Users\\[A-Za-z0-9._-]+'
hit 'email addresses' '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}'
hit 'tokens and keys' 'ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-'
# Only owner/repo pairs other than the two allowed ones count as internal names.
BAD=$(printf '%s\n' "$FILES" | while IFS= read -r f; do [ -f "$f" ] && grep -oEI 'triunai/[A-Za-z0-9._-]+' "$f" || true; done | sort -u | grep -vxE 'triunai/(bff|bff-install)' || true)
if [ -n "$BAD" ]; then echo "FAIL: other triunai repos named:"; echo "$BAD"; FAILS=$((FAILS + 1)); fi

for s in install.sh check.sh test/pipe-test.sh test/pwsh-test.sh; do
  sh -n "$s" || { echo "FAIL: sh -n $s"; FAILS=$((FAILS + 1)); }
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck install.sh check.sh test/pipe-test.sh test/pwsh-test.sh || { echo 'FAIL: shellcheck'; FAILS=$((FAILS + 1)); }
else
  echo 'note: shellcheck not installed, skipped'
fi
if LC_ALL=C grep -nP '[^\x00-\x7F]' install.ps1 install.sh >/dev/null 2>&1; then
  echo 'FAIL: non-ASCII bytes in an installer (PowerShell 5.1 reads BOM-less files as ANSI)'; FAILS=$((FAILS + 1))
fi

if [ "$FAILS" = 0 ]; then echo 'check.sh: clean'; else echo "check.sh: $FAILS problem(s)"; exit 1; fi
