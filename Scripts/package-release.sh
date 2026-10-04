#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
dmgbuild_bin="${DMGBUILD_BIN:-$(command -v dmgbuild || true)}"
if [[ -z "$dmgbuild_bin" || ! -x "$dmgbuild_bin" ]]; then
    echo 'Install Scripts/dmg-requirements.txt in a virtual environment and set DMGBUILD_BIN to its dmgbuild executable.' >&2
    exit 1
fi
UNIVERSAL=1 CONFIGURATION=release ./Scripts/build-app.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
release_dir="$project_dir/dist/release-$version"
mkdir -p "$release_dir"
stage="$(mktemp -d "${TMPDIR:-/private/tmp}/home-speaker-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto dist/HomeManager.app "$stage/Home Manager.app"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "${SIGNING_IDENTITY:-}" != 'Developer ID Application:'* ]]; then
        echo 'Notarization requires SIGNING_IDENTITY to name a Developer ID Application certificate.' >&2
        exit 1
    fi
    ditto -c -k --keepParent "$stage/Home Manager.app" "$stage/notarization.zip"
    xcrun notarytool submit "$stage/notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$stage/Home Manager.app"
    xcrun stapler validate "$stage/Home Manager.app"
    rm "$stage/notarization.zip"
    archive="Home-Manager-$version"
else
    archive="Home-Manager-$version-development"
fi
ditto -c -k --sequesterRsrc --keepParent "$stage/Home Manager.app" "$release_dir/$archive.zip"
"$dmgbuild_bin" -s "$project_dir/Scripts/dmg-settings.py" \
    -D "project_dir=$project_dir" \
    -D "app_path=$stage/Home Manager.app" \
    "Drag Home Manager to Applications" "$release_dir/$archive.dmg"
(cd "$release_dir" && shasum -a 256 "$archive.zip" "$archive.dmg" > SHA256SUMS.txt)
echo "$release_dir"
