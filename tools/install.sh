#!/bin/sh
# Install apple-tasks + apple-tasks-private into BINDIR, keeping the
# replaced copies as *.prev for `make rollback` (#69).
#
#   tools/install.sh <release_dir> <bindir> <config_dir>
#
# Each binary is staged in BINDIR, signed, then renamed over the live one
# (atomic per file). After both are in place a smoke check runs the new
# apple-tasks (`--version` must report the built commit; `dispatch-status`
# must open the ledger). A failed smoke check puts the previous binaries
# back. Every outcome is appended to <config_dir>/installs.log, and the
# repo refs deploy/current and deploy/previous move so that
# `git log deploy/previous..deploy/current` is what changed.
#
# Overrides (tests): INSTALL_SIGN (default tools/sign.sh), INSTALL_SMOKE=0,
# INSTALL_GIT_REFS=0.
set -eu

RELEASE_DIR=$1
BINDIR=$2
CONFIG_DIR=$3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIGN=${INSTALL_SIGN:-"$ROOT/tools/sign.sh"}
SMOKE=${INSTALL_SMOKE:-1}
GIT_REFS=${INSTALL_GIT_REFS:-1}
LOG="$CONFIG_DIR/installs.log"
NAMES="apple-tasks-private apple-tasks"

mkdir -p "$BINDIR" "$CONFIG_DIR"

commit_of() {
  [ -x "$1" ] || return 0
  "$1" --version 2>/dev/null | sed -n 's/.*(commit \([^)]*\)).*/\1/p' | head -n 1
}

log() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$(hostname -s 2>/dev/null || echo unknown)" "$3" >> "$LOG"
}

new_commit=$(commit_of "$RELEASE_DIR/apple-tasks")
old_commit=$(commit_of "$BINDIR/apple-tasks")
# Reinstalling the same build must not overwrite the last good .prev.
keep_prev=0
if [ -n "$new_commit" ] && [ "$new_commit" = "$old_commit" ]; then keep_prev=1; fi

# Names whose live copy this run replaced after saving it as .prev; only
# those are put back.
saved=""
restore() {
  for name in $saved; do
    if [ -e "$BINDIR/$name.prev" ]; then
      cp -p "$BINDIR/$name.prev" "$BINDIR/.restore-$name" && mv -f "$BINDIR/.restore-$name" "$BINDIR/$name"
    fi
  done
}

for name in $NAMES; do
  stage=$(mktemp -d "$BINDIR/.install-$name.XXXXXX")
  if ! { cp -p "$RELEASE_DIR/$name" "$stage/$name" && "$SIGN" "$stage/$name"; }; then
    rm -f "$stage/$name"
    rmdir "$stage"
    echo "error: installing $name into $BINDIR failed" >&2
    restore
    log "${new_commit:-unknown}" "${old_commit:-none}" "failed: stage $name"
    exit 1
  fi
  if [ -e "$BINDIR/$name" ] && [ "$keep_prev" = 0 ]; then
    cp -p "$BINDIR/$name" "$stage/$name.prev"
    mv -f "$stage/$name.prev" "$BINDIR/$name.prev"
    saved="$saved $name"
  fi
  mv -f "$stage/$name" "$BINDIR/$name"
  rmdir "$stage"
done

if [ "$SMOKE" != 0 ]; then
  installed=$(commit_of "$BINDIR/apple-tasks")
  why=""
  if [ -n "$new_commit" ] && [ "$installed" != "$new_commit" ]; then
    why="--version reports '${installed:-nothing}', expected $new_commit"
  elif ! "$BINDIR/apple-tasks" dispatch-status >/dev/null 2>&1; then
    why="dispatch-status failed"
  fi
  if [ -n "$why" ]; then
    case " $saved " in
    *" apple-tasks "*) can_restore=1 ;;
    *) can_restore=0 ;;
    esac
    if [ "$can_restore" = 1 ]; then
      restore
      log "${new_commit:-unknown}" "${old_commit:-unstamped}" "rolled back: $why"
      echo "error: smoke check failed ($why); restored ${old_commit:-the previous build}" >&2
    else
      log "${new_commit:-unknown}" "${old_commit:-none}" "smoke failed, nothing to restore: $why"
      echo "error: smoke check failed ($why) and there is no previous build to restore" >&2
    fi
    exit 1
  fi
fi

if [ "$keep_prev" = 1 ]; then
  log "$new_commit" "${old_commit:-none}" "reinstalled"
else
  log "${new_commit:-unknown}" "${old_commit:-none}" "installed"
fi

# deploy/current and deploy/previous, when the stamped commit is in this repo.
if [ "$GIT_REFS" != 0 ] && [ "$keep_prev" = 0 ] && [ -n "$new_commit" ]; then
  base=${new_commit%-dirty}
  if sha=$(git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}"); then
    if cur=$(git -C "$ROOT" rev-parse --verify --quiet refs/deploy/current); then
      git -C "$ROOT" update-ref refs/deploy/previous "$cur"
    fi
    git -C "$ROOT" update-ref refs/deploy/current "$sha"
  fi
fi

echo "installed: $BINDIR/apple-tasks — $("$BINDIR/apple-tasks" --version)"
echo "installed: $BINDIR/apple-tasks-private"
if [ -e "$BINDIR/apple-tasks.prev" ]; then
  echo "previous:  $BINDIR/apple-tasks.prev — $(commit_of "$BINDIR/apple-tasks.prev") (make rollback)"
fi
