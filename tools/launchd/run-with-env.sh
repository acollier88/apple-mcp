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
exec "$BIN" "$@"
