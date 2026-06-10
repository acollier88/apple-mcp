#!/usr/bin/env python3
"""FindMy.py sidecar for apple-tasks.

Fetches Find My network locations for your own accessories via your own
Apple account, using https://github.com/malmeloo/FindMy.py (reverse-
engineered; read-only against your account — see README caveats).

Setup (one-time, interactive):
    pip install FindMy
    python3 findmy-sidecar.py login          # Apple ID + 2FA, saves session
    # drop accessory files into ~/.config/apple-tasks/findmy/accessories/:
    #   - AirTag pairing .plist (dumped from the FindMy app; see FindMy.py docs)
    #   - or a FindMy.py accessory/keypair .json export

Agent-facing commands (JSON on stdout):
    status | devices | locate <name>
"""

import argparse
import json
import os
import sys
from pathlib import Path

CONFIG_DIR = Path(os.environ.get(
    "APPLE_TASKS_FINDMY_DIR",
    Path.home() / ".config" / "apple-tasks" / "findmy"))
ACCOUNT_FILE = CONFIG_DIR / "account.json"
ANISETTE_LIBS = CONFIG_DIR / "ani_libs.bin"
ACCESSORIES_DIR = CONFIG_DIR / "accessories"


def out(obj, code=0):
    json.dump(obj, sys.stdout, indent=2, default=str)
    print()
    sys.exit(code)


def die(message, hint=None):
    out({"error": message, **({"hint": hint} if hint else {})}, code=1)


def import_findmy():
    try:
        import findmy  # noqa: F401
        return findmy
    except ImportError:
        die("FindMy.py is not installed",
            hint="pip install FindMy  (https://github.com/malmeloo/FindMy.py)")


def load_account(findmy):
    if not ACCOUNT_FILE.exists():
        die("no Apple account session",
            hint=f"run: python3 {Path(__file__).name} login")
    return findmy.AppleAccount.from_json(
        ACCOUNT_FILE, anisette_libs_path=str(ANISETTE_LIBS))


def accessory_files():
    if not ACCESSORIES_DIR.is_dir():
        return []
    return sorted(p for p in ACCESSORIES_DIR.iterdir()
                  if p.suffix in (".plist", ".json") and p.is_file())


def load_accessory(findmy, path):
    if path.suffix == ".plist":
        return findmy.FindMyAccessory.from_plist(path, name=path.stem)
    return findmy.FindMyAccessory.from_json(path)


def accessory_name(path, accessory=None):
    name = getattr(accessory, "name", None) if accessory else None
    return name or path.stem


def cmd_status(_args):
    findmy_installed = True
    try:
        import findmy  # noqa: F401
    except ImportError:
        findmy_installed = False
    out({
        "findmyInstalled": findmy_installed,
        "accountSession": ACCOUNT_FILE.exists(),
        "accessories": [p.name for p in accessory_files()],
        "configDir": str(CONFIG_DIR),
    })


def cmd_devices(_args):
    findmy = import_findmy()
    devices = []
    for path in accessory_files():
        try:
            acc = load_accessory(findmy, path)
            devices.append({
                "name": accessory_name(path, acc),
                "file": path.name,
                "identifier": getattr(acc, "identifier", None),
                "serialNumber": getattr(acc, "serial_number", None),
                "model": getattr(acc, "model", None),
            })
        except Exception as err:  # one bad file shouldn't hide the rest
            devices.append({"name": path.stem, "file": path.name,
                            "error": str(err)})
    out(devices)


def cmd_locate(args):
    findmy = import_findmy()
    target = None
    for path in accessory_files():
        try:
            acc = load_accessory(findmy, path)
        except Exception:
            continue
        if args.name.lower() in (accessory_name(path, acc).lower(), path.stem.lower()):
            target = (path, acc)
            break
    if target is None:
        die(f"no accessory named '{args.name}'",
            hint=f"known: {[p.stem for p in accessory_files()]} "
                 f"(drop .plist/.json files in {ACCESSORIES_DIR})")

    path, acc = target
    account = load_account(findmy)
    try:
        report = account.fetch_location(acc)
    finally:
        try:
            account.to_json(ACCOUNT_FILE)  # session tokens may have rotated
            ACCOUNT_FILE.chmod(0o600)
            account.close()
        except Exception:
            pass

    if report is None:
        die(f"no recent location report for '{accessory_name(path, acc)}'")
    out({
        "name": accessory_name(path, acc),
        "latitude": getattr(report, "latitude", None),
        "longitude": getattr(report, "longitude", None),
        "timestamp": getattr(report, "timestamp", None),
        "confidence": getattr(report, "confidence", None),
        "status": getattr(report, "status", None),
    })


def cmd_login(_args):
    # Interactive only — run from a real terminal, never via MCP.
    if not sys.stdin.isatty():
        die("login is interactive; run it from a terminal")
    findmy = import_findmy()
    from getpass import getpass

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    ACCESSORIES_DIR.mkdir(parents=True, exist_ok=True)

    email = input("Apple ID email: ").strip()
    password = getpass("Password (not stored; session tokens are): ")

    ani = findmy.LocalAnisetteProvider(libs_path=str(ANISETTE_LIBS))
    account = findmy.AppleAccount(ani)
    state = account.login(email, password)

    if state == findmy.LoginState.REQUIRE_2FA:
        import re
        methods = account.get_2fa_methods()
        for i, method in enumerate(methods):
            if isinstance(method, findmy.SmsSecondFactorMethod):
                print(f"  {i} - SMS ({method.phone_number})")
            else:
                print(f"  {i} - Trusted Device")
        method = methods[int(input("2FA method # > "))]
        method.request()
        code = re.sub(r"\D", "", input("Code > "))  # digits only; "811 333" -> "811333"
        try:
            method.submit(code)
        except Exception as err:
            sys.exit(f"2FA failed ({err}). The code may have expired or been "
                     f"mistyped — run login again (SMS is the fallback if "
                     f"Trusted Device keeps failing).")

    account.to_json(ACCOUNT_FILE)
    ACCOUNT_FILE.chmod(0o600)
    account.close()
    print(f"Session saved to {ACCOUNT_FILE} (mode 600).")
    print(f"Drop AirTag pairing .plist / accessory .json files into {ACCESSORIES_DIR}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("devices")
    locate = sub.add_parser("locate")
    locate.add_argument("name")
    sub.add_parser("login")

    args = parser.parse_args()
    {"status": cmd_status, "devices": cmd_devices,
     "locate": cmd_locate, "login": cmd_login}[args.command](args)


if __name__ == "__main__":
    main()
