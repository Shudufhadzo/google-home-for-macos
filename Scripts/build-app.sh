#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/home-speaker-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/private/tmp}/home-speaker-swift-cache"

swift build --disable-sandbox --scratch-path .build

app_dir="$project_dir/dist/HomeSpeaker.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/debug/HomeSpeaker" "$app_dir/Contents/MacOS/HomeSpeaker"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/HomeSpeakerIcon.icns" "$app_dir/Contents/Resources/HomeSpeakerIcon.icns"
cp "$project_dir/Resources/HomeSpeakerIconSource.png" "$app_dir/Contents/Resources/HomeSpeakerIconSource.png"
cp "$project_dir/Resources/HomeSpeakerLogo.png" "$app_dir/Contents/Resources/HomeSpeakerLogo.png"
codesign --force --sign - "$app_dir"
echo "$app_dir"
