#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
UNIVERSAL=1 CONFIGURATION=release ./Scripts/build-app.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
release_dir="$project_dir/dist/release-$version"
mkdir -p "$release_dir"
stage="$(mktemp -d "${TMPDIR:-/private/tmp}/home-speaker-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto dist/HomeSpeaker.app "$stage/Home Speaker.app"
cp LICENSE NOTICE.md PRIVACY.md "$stage/"
ln -s /Applications "$stage/Applications"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "${SIGNING_IDENTITY:-}" != 'Developer ID Application:'* ]]; then
        echo 'Notarization requires SIGNING_IDENTITY to name a Developer ID Application certificate.' >&2
        exit 1
    fi
    ditto -c -k --keepParent "$stage/Home Speaker.app" "$stage/notarization.zip"
    xcrun notarytool submit "$stage/notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$stage/Home Speaker.app"
    xcrun stapler validate "$stage/Home Speaker.app"
    rm "$stage/notarization.zip"
    flavor='notarized'
else
    flavor='development'
    printf '%s\n' 'Development build: not notarized for public distribution.' > "$stage/BUILD-STATUS.txt"
fi
archive="Home-Speaker-$version-universal-$flavor"
ditto -c -k --sequesterRsrc --keepParent "$stage/Home Speaker.app" "$release_dir/$archive.zip"
hdiutil create -volname "Home Speaker $version" -srcfolder "$stage" -ov -format UDZO "$release_dir/$archive.dmg"
(cd "$release_dir" && shasum -a 256 "$archive.zip" "$archive.dmg" > SHA256SUMS.txt)
echo "$release_dir"
