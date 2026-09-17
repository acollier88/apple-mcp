#!/bin/sh
# Stand-in for the apple-tasks Swift CLI used by MCP smoke tests.

if [ -n "$FAKE_ARGV_LOG" ]; then
  printf '%s\n' "$*" >> "$FAKE_ARGV_LOG"
fi

if [ -n "$FAKE_EXIT" ] && [ "$FAKE_EXIT" != "0" ]; then
  printf '%s\n' "fake failure" >&2
  exit "$FAKE_EXIT"
fi

case "$1" in
  list)
    printf '%s\n' '[{"id":"T1","title":"Hello","rawTitle":"[claude] Hello","tags":["claude"],"list":"Inbox","priority":"none","completed":false}]'
    ;;
  dispatch)
    printf '%s\n' '[]'
    ;;
  dispatches)
    printf '%s\n' '[]'
    ;;
  doctor)
    printf '%s\n' '{"ok":true}'
    ;;
  dispatch-pause)
    printf '%s\n' '{"paused":true,"until":"2026-09-08T12:00:00Z","reason":"probe"}'
    ;;
  dispatch-status)
    printf '%s\n' '{"paused":false}'
    ;;
  remirror-tags)
    printf '%s\n' '[{"id":"T1","rawTitle":"[claude] Hello","tags":["claude"],"nativeBefore":["claude","claude"],"pruned":[],"duplicatesRemoved":1,"added":0}]'
    ;;
  add-batch)
    cat >/dev/null
    printf '%s\n' '{"created":[],"failed":[]}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac

exit 0
