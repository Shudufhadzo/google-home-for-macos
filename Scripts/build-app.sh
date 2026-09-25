#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/home-speaker-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/private/tmp}/home-speaker-swift-cache"
configuration="${CONFIGURATION:-release}"
build_args=(--configuration "$configuration" --disable-sandbox --scratch-path .build)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$project_dir/dist/HomeSpeaker.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/HomeSpeaker" "$app_dir/Contents/MacOS/HomeSpeaker"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
for asset in HomeSpeakerIcon.icns HomeSpeakerIconSource.png HomeSpeakerLogo.png; do
    cp "Resources/$asset" "$app_dir/Contents/Resources/$asset"
done
cp LICENSE NOTICE.md PRIVACY.md "$app_dir/Contents/Resources/"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/HomeSpeaker.entitlements --sign "$SIGNING_IDENTITY" "$app_dir"
else
    codesign --force --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
