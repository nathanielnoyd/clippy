#!/bin/zsh
# Builds a release Clippy.app in ./build. Usage: scripts/build-app.sh
#
# Uses xcodebuild (not `swift build`) because it also emits the compiler's
# constant-value data, which the App Intents metadata processor needs so Siri,
# Shortcuts and Spotlight can find "Ask Clippy".
set -euo pipefail
cd "${0:A:h}/.."

work=build/work
mkdir -p "$work"

# (The grep hides xcodebuild's harmless "multiple matching destinations" list.)
xcodebuild -quiet -scheme Clippy -destination 'generic/platform=macOS' \
    -configuration Release -derivedDataPath "$work/derived" build 2>&1 \
    | { grep -vE '^\s*\{ platform:|multiple matching destinations|IDERunDestination|Using the first of multiple' || true; }

bin="$work/derived/Build/Products/Release/Clippy"
constvals=$(find "$work/derived/Build/Intermediates.noindex" -name '*.swiftconstvalues' -path '*Release*' | head -1)

# App Intents metadata (Metadata.appintents).
print -l "$PWD"/Sources/Clippy/*.swift > "$work/sources.txt"
print -r -- "$PWD/$constvals" > "$work/constvals.txt"
rm -rf "$work/intents" && mkdir -p "$work/intents"
xcrun appintentsmetadataprocessor \
    --output "$work/intents" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --module-name Clippy \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple arm64-apple-macos14.0 \
    --source-file-list "$work/sources.txt" \
    --swift-const-vals-list "$work/constvals.txt" \
    --force --quiet-warnings 2>&1 | grep -v "appintentsmetadataprocessor\[" || true

app=build/Clippy.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Clippy"
cp Support/Info.plist "$app/Contents/Info.plist"
cp -R "$work/intents/Metadata.appintents" "$app/Contents/Resources/"

# Icon from the character pack you use (or any imported one); the placeholder if there's none.
pack=$(defaults read local.clippy.app lastPackPath 2>/dev/null || true)
imported=(~/Library/Application\ Support/Clippy/Packs/*/agent.json(N))
[[ -f "$pack/agent.json" ]] || pack=${imported[1]:+${imported[1]:h}}
swift scripts/make-icon.swift "$app/Contents/Resources/AppIcon.icns" ${pack:+"$pack"}

# Ad-hoc signature so macOS can track permissions (local network, Keychain) for the app.
codesign --force --sign - "$app"

# Tell Launch Services about the new build so Shortcuts and Siri pick up its intents.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"

echo "Built $app. Open it with: open $app"
