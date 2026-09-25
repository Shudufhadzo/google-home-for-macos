# Building a macOS distribution

## Development package

Run `./Scripts/package-release.sh` using Xcode 26 or newer. It creates a universal (Apple silicon + Intel) app in `dist/HomeSpeaker.app` and a DMG, ZIP, and SHA-256 manifest in `dist/release-<version>/`. These artifacts are ignored by Git. The app includes the license and notices.

Without a signing identity, these are **ad-hoc signed development builds**, not notarized public downloads. macOS may block downloaded copies. Build from source for development; do not disable Gatekeeper or strip quarantine as an installation step.

## Notarized public package

The releasing maintainer needs a Developer ID Application certificate with its private key and a configured `notarytool` keychain profile. An Apple Development certificate is not a substitute.

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-notary-profile' \
./Scripts/package-release.sh
```

The script enables hardened runtime, signs with the Automation entitlement, submits the app to Apple, staples and validates the ticket, and packages the result. It exits if notarization fails. Keep credentials and signing files out of Git.

Before publishing a GitHub release:

- Run tests and CI; verify `lipo -archs` contains `arm64 x86_64`.
- Validate the app signature and notarization ticket.
- On a separate Mac, mount the DMG, drag Home Speaker to Applications, launch it, and allow Local Network, System Audio Recording, and Music Automation as requested.
- With an actual speaker, test discovery, casting, Next/Previous, phone title/artwork, Stop, and restoration of Mac audio. Distinguish synthetic tests from listening results.
- Attach the notarized DMG, ZIP, checksums, known limits, and release notes to a versioned GitHub release.

Version 0.4.1 is currently an early development release. Public source availability does not imply Apple notarization or App Store approval.
