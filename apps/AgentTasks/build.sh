#!/bin/bash
# Hand-rolled .app build with App Intents metadata extraction (no Xcode project).
set -euo pipefail
cd "$(dirname "$0")"

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

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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

echo "== registering with LaunchServices =="
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP"

echo "done: $PWD/$APP"
