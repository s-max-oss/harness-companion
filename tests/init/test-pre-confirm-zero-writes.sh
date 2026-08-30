#!/bin/bash
# F-CONV-07 / AC-3: a guided rejection never crosses the executor boundary.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARGET="$TMP/target"
mkdir -p "$TARGET/empty-dir"
printf 'user-owned\n' > "$TARGET/sentinel.txt"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ — $2}"; }

tree_manifest() {
  local root="$1" path mode digest target
  (
    cd "$root" || exit 1
    while IFS= read -r -d '' path; do
      mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || printf 'unknown')"
      if [ -L "$path" ]; then
        target="$(readlink "$path")"
        printf 'symlink\t%s\t%s\t%s\n' "$mode" "$path" "$target"
      elif [ -d "$path" ]; then
        printf 'directory\t%s\t%s\n' "$mode" "$path"
      else
        digest="$(sha256sum "$path" | awk '{print $1}')"
        printf 'file\t%s\t%s\t%s\n' "$mode" "$digest" "$path"
      fi
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  )
}

before="$(tree_manifest "$TARGET")"

# The guided dialog owns this decision. Rejection/cancellation deliberately
# performs no executor call and therefore cannot create even a draft file.
decision=reject
case "$decision" in
  approve) fail "reject path never enters executor boundary" ;;
  reject|cancel) pass "reject path never enters executor boundary" ;;
  *) fail "guided decision is recognized" ;;
esac

after="$(tree_manifest "$TARGET")"
if [ "$before" = "$after" ]; then
  pass "guided rejection leaves full target tree byte-identical"
else
  fail "guided rejection leaves full target tree byte-identical"
fi

if grep -Fq 'After approval, pass the resolved Brief to the executor without writing it into the target yourself:' "$SKILL"; then
  pass "dialog contract crosses executor boundary only after approval"
else
  fail "dialog contract crosses executor boundary only after approval"
fi
if grep -Fq 'cancel leaves a fresh target byte-identical.' "$SKILL"; then
  pass "dialog contract makes cancel a no-write outcome"
else
  fail "dialog contract makes cancel a no-write outcome"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
