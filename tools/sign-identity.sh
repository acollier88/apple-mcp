#!/bin/bash
# Create a persistent self-signed codesigning identity named "AgentTasks Dev".
#
# Default target is the login keychain. Override with KEYCHAIN=/path/to.keychain-db
# (and KEYCHAIN_PASSWORD=...) to use a throwaway keychain — do not point this at
# the login keychain from automated tests.
#
# Login keychain: `security set-key-partition-list` needs the keychain password
# so codesign can use the key without a GUI prompt. This script asks on a TTY.
#
# Trusting the cert for the codeSign policy (`security add-trusted-cert`) needs
# admin and is best-effort. An untrusted self-signed identity still works for
# `codesign -s` and yields a stable designated requirement (TCC / Keychain ACLs).
set -euo pipefail

CERT_NAME="AgentTasks Dev"
DRY_RUN="${DRY_RUN:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

keychain_path() {
  if [[ -n "${KEYCHAIN:-}" ]]; then
    printf '%s' "$KEYCHAIN"
    return
  fi
  security default-keychain -d user | tr -d '"[:space:]'
}

find_identities() {
  # $1 optional: -v (valid only). Untrusted self-signed certs often appear
  # only without -v; callers try -v first.
  local -a args=(-p codesigning)
  if [[ "${1:-}" == "-v" ]]; then
    args=(-v -p codesigning)
  fi
  if [[ -n "${KEYCHAIN:-}" ]]; then
    security find-identity "${args[@]}" "$KEYCHAIN"
  else
    security find-identity "${args[@]}"
  fi
}

identity_present() {
  find_identities -v 2>/dev/null | grep -q "$CERT_NAME" \
    || find_identities 2>/dev/null | grep -q "$CERT_NAME"
}

if identity_present; then
  echo "identity already present: $CERT_NAME"
  exit 0
fi

kc="$(keychain_path)"
echo "creating identity '$CERT_NAME' in $kc"

if [[ -n "${KEYCHAIN:-}" && -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  run security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# OpenSSL 3 ships -addext / -legacy; LibreSSL 3.3 has -addext but not -legacy.
# -legacy is required on OpenSSL 3 so `security import` can read the PKCS#12
# (default PBES2/AES is rejected as an unknown MAC / alg).
req=(
  openssl req -x509 -newkey rsa:2048
  -keyout "$tmpdir/k.pem"
  -out "$tmpdir/c.pem"
  -days 3650
  -nodes
  -subj "/CN=$CERT_NAME"
  -addext "keyUsage=critical,digitalSignature"
  -addext "extendedKeyUsage=critical,codeSigning"
)
run "${req[@]}"
if [[ "$DRY_RUN" == "1" ]]; then
  # Placeholders so later dry-run lines have a path to print.
  : >"$tmpdir/k.pem"
  : >"$tmpdir/c.pem"
fi

# PKCS#12 transport password. Empty `-passout pass:` / `-P ''` is what we
# want, but OpenSSL 3 + this macOS `security import` rejects it ("MAC
# verification failed"). A throwaway passphrase on the ephemeral .p12 works;
# it is not the keychain password and the file is deleted after import.
p12=(
  openssl pkcs12 -export
  -inkey "$tmpdir/k.pem"
  -in "$tmpdir/c.pem"
  -out "$tmpdir/x.p12"
  -name "$CERT_NAME"
  -passout pass:
)
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
  p12+=(-legacy)
fi
run "${p12[@]}"
if [[ "$DRY_RUN" == "1" ]]; then
  : >"$tmpdir/x.p12"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry-run: security import $tmpdir/x.p12 -k $kc -T /usr/bin/codesign -P ''"
else
  if ! security import "$tmpdir/x.p12" -k "$kc" -T /usr/bin/codesign -P '' 2>/dev/null; then
    echo "note: empty PKCS#12 password rejected by security import; retrying with a throwaway transport passphrase + -legacy"
    p12_pass="agenttasks-p12"
    p12_retry=(
      openssl pkcs12 -export
      -inkey "$tmpdir/k.pem"
      -in "$tmpdir/c.pem"
      -out "$tmpdir/x.p12"
      -name "$CERT_NAME"
      -passout "pass:$p12_pass"
    )
    if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
      p12_retry+=(-legacy)
    fi
    "${p12_retry[@]}"
    security import "$tmpdir/x.p12" -k "$kc" -T /usr/bin/codesign -P "$p12_pass"
  fi
fi

echo "set-key-partition-list lets codesign use the key without a Keychain GUI prompt."
echo "  it needs the keychain password (login keychain: your macOS login password)."
if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  run security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$kc"
elif [[ -n "${KEYCHAIN:-}" ]]; then
  echo "warning: skipped set-key-partition-list (set KEYCHAIN_PASSWORD for a custom keychain)" >&2
elif [[ "$DRY_RUN" == "1" ]]; then
  echo "dry-run: security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <login-password> $kc"
elif [[ -t 0 ]]; then
  read -r -s -p "Login keychain password: " login_pw
  echo
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$login_pw" "$kc"
else
  echo "  not a TTY — run: security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> $kc"
fi

echo "Trust for the codeSign policy is optional and needs admin:"
echo "  security add-trusted-cert -d -r trustRoot -p codeSign -k $kc <cert.pem>"
echo "  Untrusted self-signed identities still work for codesign -s and give a stable designated requirement."
if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry-run: security add-trusted-cert -d -r trustRoot -p codeSign -k $kc $tmpdir/c.pem"
elif [[ -z "${KEYCHAIN:-}" && -t 0 ]]; then
  if security add-trusted-cert -d -r trustRoot -p codeSign -k "$kc" "$tmpdir/c.pem"; then
    echo "trusted: $CERT_NAME for codeSign"
  else
    echo "note: could not add trust (admin required). Signing still works; TCC/Keychain grants follow the designated requirement."
  fi
else
  echo "note: skipped add-trusted-cert (non-interactive or KEYCHAIN= override; run the command above to trust)."
fi

echo "created identity: $CERT_NAME"
