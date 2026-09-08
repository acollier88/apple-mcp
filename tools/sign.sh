#!/bin/bash
# Sign one or more Mach-O binaries / .app bundles with "AgentTasks Dev" when
# that identity is present. Used by the top-level Makefile (cli + helper) and
# apps/AgentTasks/build.sh so there is a single codesign invocation.
#
#   SIGN_IDENTITY   override (name or hash). Default: find-identity AgentTasks Dev
#   KEYCHAIN        optional keychain path (passed to find-identity and codesign)
#   DRY_RUN=1       print codesign lines; do not execute
#
# Ad-hoc fallback:
#   .app bundles  — `codesign --force --deep -s -` (same as historical build.sh)
#   CLI binaries  — leave as SwiftPM/clang produced them. On Apple Silicon the
#                   linker already embeds adhoc,linker-signed (codesign -dv).
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

usage() {
  echo "usage: sign.sh [--dry-run] <path>..." >&2
  exit 2
}

[[ $# -gt 0 ]] || usage

find_dev_identity() {
  local -a args=(-v -p codesigning)
  if [[ "${1:-}" == "any" ]]; then
    args=(-p codesigning)
  fi
  if [[ -n "${KEYCHAIN:-}" ]]; then
    security find-identity "${args[@]}" "$KEYCHAIN"
  else
    security find-identity "${args[@]}"
  fi
}

# Same resolution the Makefile / build.sh use. Prefer -v (valid); fall back to
# any identity so an untrusted self-signed cert still signs.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_dev_identity 2>/dev/null | awk -F'"' '/AgentTasks Dev/{print $2; exit}')}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(find_dev_identity any 2>/dev/null | awk -F'"' '/AgentTasks Dev/{print $2; exit}')}"

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

for path in "$@"; do
  if [[ "$DRY_RUN" != "1" && ! -e "$path" ]]; then
    echo "error: $path not found" >&2
    exit 1
  fi

  if [[ -n "$SIGN_IDENTITY" ]]; then
    # Build argv in one array so empty optional flags are safe under `set -u`.
    cmd=(codesign --force --sign "$SIGN_IDENTITY" --timestamp=none)
    if [[ -n "${KEYCHAIN:-}" ]]; then
      cmd+=(--keychain "$KEYCHAIN")
    fi
    if [[ "$path" == *.app ]]; then
      cmd+=(--deep)
    fi
    cmd+=("$path")
    echo "signing: $path as $SIGN_IDENTITY"
    # No --options runtime: hardened runtime can break the private-API helper
    # and App Intents dev builds.
    run "${cmd[@]}"
  elif [[ "$path" == *.app ]]; then
    echo "signing: ad-hoc (run 'make sign-identity' for a stable identity)"
    run codesign --force --deep -s - "$path"
  else
    echo "signing: $path unchanged (linker ad-hoc; run 'make sign-identity' for a stable identity)"
  fi
done
