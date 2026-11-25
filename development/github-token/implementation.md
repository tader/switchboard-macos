# GitHub installation token

The app stores its optional token in a dedicated generic-password Keychain item, outside Codable Settings. GitHub REST requests read it only for the exact HTTPS API origin. Redirect delegates remove authorization outside that origin. Public assets and Sparkle feeds do not receive the token.

Startup adds SWITCHBOARD_PLUGIN_INSTALL_GITHUB_TOKEN to the private pipe environment, never argv or persisted settings. Changes require a server restart. Synthetic tests cover header origin boundaries, normalization, error classification and serialized settings.

Verification: swift test passed 39 tests, with one existing packaged-runtime fixture test skipped. The isolated native Keychain roundtrip passed. Updated settings renders were inspected at narrow width in light and dark appearance. git diff --check passed.
