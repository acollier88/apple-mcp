#!/bin/bash
# Hand-rolled .app build with App Intents metadata extraction (no Xcode project).
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"

# Use the Xcode 27 beta when present (Reminders domain schemas need its SDK).
if [ -d /Applications/Xcode-beta.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

APP=build/AgentTasks.app
TRIPLE=arm64-apple-macos27.0
DEPLOYMENT=27.0
TOOLCHAIN=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/Toolchains/XcodeDefault.xctoolchain
SDK=$(xcrun --sdk macosx --show-sdk-path)
XCODE_BUILD=$(xcodebuild -version | awk '/Build version/{print $3}')

# Ensure the CLI the app shells to exists, and stamp its absolute path into the
# bundle so /Applications/AgentTasks.app still finds it after install.
echo "== ensuring CLI + native-tag helper =="
# `all` builds apple-tasks and the sibling apple-tasks-private ReminderKit
# helper. Without the helper, add/update only write [tag] title prefixes.
make -C "$REPO_ROOT/cli" all
CLI_BIN=""
for candidate in \
    "$REPO_ROOT/cli/.build/release/apple-tasks" \
    "$REPO_ROOT/cli/.build/out/Products/Release/apple-tasks"; do
    if [[ -x "$candidate" ]]; then
        CLI_BIN="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
        break
    fi
done
if [[ -z "$CLI_BIN" ]]; then
    echo "error: apple-tasks binary missing after make -C cli" >&2
    exit 1
fi
HELPER_BIN="$(dirname "$CLI_BIN")/apple-tasks-private"
if [[ ! -x "$HELPER_BIN" ]]; then
    echo "error: apple-tasks-private missing next to CLI ($HELPER_BIN) — native Reminders tags will not mirror" >&2
    exit 1
fi
echo "    CLI: $CLI_BIN"
echo "    helper: $HELPER_BIN"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/recipes"
printf '%s\n' "$CLI_BIN" > "$APP/Contents/Resources/apple-tasks-bin.path"
# Bundled task recipes (seeded into ~/.config/apple-tasks/recipes/ on first open).
if [[ -d "$REPO_ROOT/examples/recipes" ]]; then
    find "$REPO_ROOT/examples/recipes" -maxdepth 1 -name '*.json' -exec cp {} "$APP/Contents/Resources/recipes/" \;
    echo "    recipes: $(ls "$APP/Contents/Resources/recipes"/*.json 2>/dev/null | wc -l | tr -d ' ') bundled"
fi

echo "== compiling =="
# The frontend wants a flat JSON array; the toolchain ships a versioned wrapper.
CONST_PROTOCOLS="$PWD/build/const-protocols.json"
python3 -c "
import json
src = '$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json'
print(json.dumps(json.load(open(src))['constValueProtocols']))
" > "$CONST_PROTOCOLS"
swiftc -c -O -whole-module-optimization -parse-as-library \
    -target "$TRIPLE" -module-name AgentTasks \
    -emit-const-values-path build/AgentTasks.swiftconstvalues \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$CONST_PROTOCOLS" \
    Sources/*.swift \
    -o build/AgentTasks.o

swiftc -target "$TRIPLE" build/AgentTasks.o -o "$APP/Contents/MacOS/AgentTasks"

cp Info.plist "$APP/Contents/Info.plist"

echo "== extracting App Intents metadata =="
ls Sources/*.swift | sed "s|^|$PWD/|" > build/sources.txt
echo "$PWD/build/AgentTasks.swiftconstvalues" > build/constvals.txt

xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name AgentTasks \
    --sdk-root "$SDK" \
    --xcode-version "$XCODE_BUILD" \
    --platform-family macOS \
    --deployment-target $DEPLOYMENT \
    --target-triple "$TRIPLE" \
    --source-file-list build/sources.txt \
    --swift-const-vals-list build/constvals.txt \
    --binary-file "$APP/Contents/MacOS/AgentTasks" \
    --compile-time-extraction \
    --no-app-shortcuts-localization \
    --validate-assistant-intents \
    --force

echo "== signing (ad hoc) =="
codesign --force --deep -s - "$APP"

# Replace the installed app so Spotlight/Siri/Dock always see this build.
INSTALL_APP=/Applications/AgentTasks.app
echo "== installing to $INSTALL_APP =="
# Quit a running copy so we can replace the bundle (best-effort).
osascript -e 'tell application "AgentTasks" to quit' >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$INSTALL_APP"
ditto "$APP" "$INSTALL_APP"
codesign --force --deep -s - "$INSTALL_APP"

echo "== registering with LaunchServices =="
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$INSTALL_APP"
# Drop the build-tree copy from the LS database so it doesn't compete.
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true

echo "done: $INSTALL_APP (build tree: $PWD/$APP)"
