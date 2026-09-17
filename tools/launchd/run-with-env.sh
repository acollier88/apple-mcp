#!/bin/bash
# Wrapper used by LaunchAgents so optional ~/.config/apple-tasks/launchd.env
# (CURSOR_API_KEY, ANTHROPIC_API_KEY, extra PATH, …) is loaded before the CLI.
# Args: <apple-tasks-bin> <subcommand...>
set -euo pipefail
BIN="${1:?apple-tasks binary required}"
shift
ENV_FILE="${HOME}/.config/apple-tasks/launchd.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
# Rotate launchd logs before they grow without bound (5 MiB).
LOG_DIR="${HOME}/.config/apple-tasks/logs"
if [[ -d "$LOG_DIR" ]]; then
  for f in "$LOG_DIR"/*.log; do
    [[ -f "$f" ]] || continue
    size="$(stat -f %z "$f" 2>/dev/null || echo 0)"
    if [[ "$size" -gt 5242880 ]]; then
      mv -f "$f" "${f}.1"
    fi
  done
fi
exec "$BIN" "$@"
