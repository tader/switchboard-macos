# Native app self-updates

## Implementation

Pinned Sparkle 2.10.1 checks architecture-specific GitHub release feeds. Default checks are automatic, installation always requires confirmation, and profiling is disabled. Signed feeds and EdDSA archive verification are required; feed-signature failure expiration is disabled. Only Developer ID release signing enables live updating. Framework helpers are re-signed inside out before the app is notarized. Unsigned bundles remain runnable with app updating disabled.

Settings distinguishes app updates from server runtime updates and offers a manual app check and an automatic-check toggle. Sparkle defers its relaunch until the manager stops its owned server and finishes any active install cleanup. Existing shutdown semantics protect managed cutovers.

Release automation derives and compares the signing identity with the bundled public key, validates archive identity/version, uses official Sparkle tools to sign the feed/archive, verifies both, and publishes only signed architecture-specific feeds. The setup helper refuses to overwrite existing signing secrets and keeps private material out of arguments, logs and source control.

## Validation

- Swift build succeeded; 34 native tests passed against the published core runtime with no skips, including app-update shutdown during pending installation cleanup.
- Six release-tool tests passed, including nested signing order and unsigned/signed enablement.
- Three real Sparkle feed tests passed with disposable keys: valid archive/feed, wrong key, invalid versions/keys, and tampered archive/feed rejection.
- Two configuration safety tests passed using mocked Keychain/GitHub operations; secret transport uses stdin and temporary exports are removed.
- The updated app was bundled with its framework and portable rpath. Native settings light/dark renders were generated for inspection.

## Signing setup and limits

The maintainer explicitly approved production signing setup. The dedicated key is retained in the macOS login Keychain, and its private seed is configured as the repository’s `SPARKLE_PRIVATE_KEY` Actions secret. Only `Assets/update-public-key.txt` is committed. The public key matches the Keychain identity and a signing/verification round trip succeeded. Temporary exports were removed; no private material was logged or committed.

No real user app has been replaced, no live install was forced, and Developer ID/notarization verification for these new framework components must run in release CI. Older app versions require one manual update to acquire the updater.
