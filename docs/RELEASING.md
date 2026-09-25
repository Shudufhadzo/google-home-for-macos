# Building a macOS distribution

## Development package

Use Xcode 26 or newer. Install the pinned DMG builder in a virtual environment, then run the packaging script:

```sh
python3 -m venv /private/tmp/home-speaker-dmg-venv
/private/tmp/home-speaker-dmg-venv/bin/python -m pip install -r Scripts/dmg-requirements.txt
DMGBUILD_BIN=/private/tmp/home-speaker-dmg-venv/bin/dmgbuild ./Scripts/package-release.sh
```

It creates a universal (Apple silicon + Intel) app in `dist/HomeSpeaker.app` and a DMG, ZIP, and SHA-256 manifest in `dist/release-<version>/`. These artifacts are ignored by Git. The app bundle includes the license, notices, and privacy information. The DMG presents the app, drag arrow, and Applications shortcut in a Finder window titled "Drag Home Speaker to Applications". To regenerate the arrow after changing its renderer, run `swift Scripts/render-dmg-arrow.swift Resources/DMGDragArrow.png`.

Without a signing identity, these are **ad-hoc signed development builds** with `-development` in their filenames. macOS may block downloaded copies. Build from source for development; do not disable Gatekeeper or strip quarantine as an installation step.

The 0.4.1 release retains clearly labeled development packages for reference. The README links to the notarized packages for installation. If macOS blocks a development package, use the notarized download or build from source using the README instructions.

## Notarized public package

The releasing maintainer needs a Developer ID Application certificate with its private key and a configured `notarytool` keychain profile. An Apple Development certificate is not a substitute.

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-notary-profile' \
DMGBUILD_BIN=/private/tmp/home-speaker-dmg-venv/bin/dmgbuild \
./Scripts/package-release.sh
```

The script enables hardened runtime, signs with the Automation entitlement, submits the app to Apple, staples and validates the ticket, and packages the result. Public artifacts use plain names such as `Home-Speaker-0.4.2.dmg` and `Home-Speaker-0.4.2.zip`; signing and notarization are verified release properties, not filename suffixes. It exits if notarization fails. Keep credentials and signing files out of Git.

Before publishing a stable, notarized GitHub release:

- Run tests and CI; verify `lipo -archs` contains `arm64 x86_64`.
- Validate the app signature and notarization ticket.
- On a separate Mac, mount the DMG, drag Home Speaker to Applications, launch it, and allow Local Network, System Audio Recording, and Music Automation as requested.
- With an actual speaker, test discovery, casting, Next/Previous, phone title/artwork, Stop, and restoration of Mac audio. Distinguish synthetic tests from listening results.
- Attach the notarized DMG, ZIP, checksums, known limits, and release notes to a versioned GitHub release.

Version 0.4.1 is an early notarized prerelease. Its signed app passed strict code-signature verification, stapler validation, and Gatekeeper assessment as `Notarized Developer ID`. Notarization is separate from Mac App Store approval.
