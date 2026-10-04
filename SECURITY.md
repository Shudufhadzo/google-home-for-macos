# Security

Use local HTTP and casting on a trusted local network. Audio is served through a temporary local HTTP endpoint; random URLs reduce accidental discovery but are not authentication. Home Assistant bearer tokens live in Keychain; use HTTPS for remote hubs, and a trusted certificate. Authenticated API redirects are rejected. Discovery data is untrusted and cannot create credentials or native controls. See [PRIVACY.md](PRIVACY.md) for the data flow and certificate limitations.

Report a suspected vulnerability using the repository's **Security → Report a vulnerability** feature when available. If private reporting is unavailable, open an issue asking for a private contact method without including exploit details, credentials, audio, or personal network information.

This is an early release. It has not undergone an independent security audit. Do not disable macOS security protections to run a build. Public binaries should be Developer ID signed and notarized; local ad-hoc builds are intended for development and testing.
