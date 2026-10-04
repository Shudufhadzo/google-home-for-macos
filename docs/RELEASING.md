# Building a macOS distribution

## Development package

Use Xcode 26 or newer. Install the pinned DMG builder in a virtual environment, then run the packaging script:

```sh
python3 -m venv /private/tmp/home-speaker-dmg-venv
/private/tmp/home-speaker-dmg-venv/bin/python -m pip install -r Scripts/dmg-requirements.txt
DMGBUILD_BIN=/private/tmp/home-speaker-dmg-venv/bin/dmgbuild ./Scripts/package-release.sh
```

It creates a universal (Apple silicon + Intel) app in `dist/HomeManager.app` and a DMG, ZIP, and SHA-256 manifest in `dist/release-<version>/`. These artifacts are ignored by Git. The executable remains `HomeSpeaker`. The app bundle includes the license, notices, and privacy information. The DMG presents the app, drag arrow, and Applications shortcut in a Finder window titled "Drag Home Manager to Applications". To regenerate the arrow after changing its renderer, run `swift Scripts/render-dmg-arrow.swift Resources/DMGDragArrow.png`.

Without a signing identity, these are **ad-hoc signed development builds** with `-development` in their filenames. macOS may block downloaded copies. Build from source for development; do not disable Gatekeeper or strip quarantine as an installation step.

The current GitHub preview is Home Manager 0.5.6. Its universal DMG and ZIP are signed and notarized independently of the historical Home Speaker 0.4.2 release. See [0.5.6 release notes](RELEASE-NOTES-0.5.6.md) and [release verification](VERIFICATION-0.5.6.md) for the exact checks and physical-device limits.

## Notarized public package

The releasing maintainer needs a Developer ID Application certificate with its private key and a configured `notarytool` keychain profile. An Apple Development certificate is not a substitute.

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-notary-profile' \
DMGBUILD_BIN=/private/tmp/home-speaker-dmg-venv/bin/dmgbuild \
./Scripts/package-release.sh
```

The script enables hardened runtime, signs with the Automation entitlement, submits the app to Apple, staples and validates the ticket, and packages the result. Public artifacts use names such as `Home-Manager-<version>.dmg` and `Home-Manager-<version>.zip`; signing and notarization are verified release properties, not filename suffixes. It exits if notarization fails. Keep credentials and signing files out of Git.

Before publishing a stable, notarized GitHub release:

- Run tests and CI; verify `lipo -archs` contains `arm64 x86_64`.
- Validate the app signature and notarization ticket.
- Mount the final DMG and verify the contained app's strict signature and stapled ticket. Finder metadata must not invalidate the signed app; never set an extension-hidden FinderInfo flag on the app bundle.
- On a separate Mac, mount the DMG, drag Home Manager to Applications, launch it, and allow Local Network, System Audio Recording, and Music Automation as requested.
- With an actual speaker, test discovery, casting, Next/Previous, phone title/artwork, Stop, and restoration of Mac audio. Distinguish synthetic tests from listening results.
- Test an authenticated Home Assistant installation and specific third-party devices/firmware. Report gateway/Bonjour/SSDP discovery, management-page access, synthetic hub tests, real hub commands, and physical behavior as separate evidence.
- Attach the notarized DMG, ZIP, checksums, known limits, and release notes to a versioned GitHub release.

Notarization is separate from Mac App Store approval and from physical-device compatibility. The new Home Manager version does not inherit the old speaker package's signing/notarization claims.
