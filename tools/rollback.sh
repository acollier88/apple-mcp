#!/bin/sh
# Swap apple-tasks and apple-tasks-private with their *.prev copies (#69).
# Running it twice returns to where you started.
#
#   tools/rollback.sh <bindir> <config_dir>
set -eu

BINDIR=$1
CONFIG_DIR=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GIT_REFS=${INSTALL_GIT_REFS:-1}
LOG="$CONFIG_DIR/installs.log"
mkdir -p "$CONFIG_DIR"

commit_of() {
  [ -x "$1" ] || return 0
  "$1" --version 2>/dev/null | sed -n 's/.*(commit \([^)]*\)).*/\1/p' | head -n 1
}

if [ ! -e "$BINDIR/apple-tasks.prev" ]; then
  echo "error: no $BINDIR/apple-tasks.prev to roll back to (it is kept by make install)" >&2
  exit 1
fi
from=$(commit_of "$BINDIR/apple-tasks")
to=$(commit_of "$BINDIR/apple-tasks.prev")

for name in apple-tasks-private apple-tasks; do
  [ -e "$BINDIR/$name.prev" ] || continue
  # Copy the live one aside, rename .prev over it (atomic), then keep the
  # copy as the new .prev.
  if [ -e "$BINDIR/$name" ]; then cp -p "$BINDIR/$name" "$BINDIR/.rollback-$name"; fi
  mv -f "$BINDIR/$name.prev" "$BINDIR/$name"
  if [ -e "$BINDIR/.rollback-$name" ]; then mv -f "$BINDIR/.rollback-$name" "$BINDIR/$name.prev"; fi
done

printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${to:-unstamped}" "${from:-unstamped}" \
  "$(hostname -s 2>/dev/null || echo unknown)" "rollback" >> "$LOG"

if [ "$GIT_REFS" != 0 ]; then
  cur=$(git -C "$ROOT" rev-parse --verify --quiet refs/deploy/current || true)
  prev=$(git -C "$ROOT" rev-parse --verify --quiet refs/deploy/previous || true)
  if [ -n "$cur" ] && [ -n "$prev" ]; then
    git -C "$ROOT" update-ref refs/deploy/current "$prev"
    git -C "$ROOT" update-ref refs/deploy/previous "$cur"
  fi
fi

echo "rolled back: $BINDIR/apple-tasks — ${from:-unstamped} -> ${to:-unstamped}"
echo "run make rollback again to return to ${from:-the build you replaced}"
