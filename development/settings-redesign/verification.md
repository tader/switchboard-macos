# Settings redesign verification

## Result

General settings focus on status, account access, startup and release channels. Advanced contains paths, networking, version pinning and maintenance. Preferences do not complete onboarding; setup and installation share channel/pin resolution. Byte progress comes from the actual transfer, with separate preparation and commit states.

The app icon is bundled as AppIcon.icns and shown in Settings; the menu-bar glyph remains a native monochrome symbol. The source image and generation prompt are in Assets.

Account setup and recovery use browser forms. Only the recovery method can write a recovery command, after a fresh macOS device-owner authentication and a session recheck. Generic commands reject recovery actions. Responses are correlated to the pending request and checked against the local server origin. Recovery links are opened and discarded, not retained as setup links. Stop/restart resets the account session; dismissed requests cannot open a late recovery link.

## Checks performed

- Full native suite: 31 passed, one packaged-runtime extraction test skipped because release assets were not supplied.
- Security cases include authentication denial/cancellation, a new authentication for every request, invalid origins, stale/dismissed sessions, unsupported runtimes, and non-retention of recovery URLs.
- Latest UI render pass succeeded for setup, Advanced, download, error, recovery and unsupported recovery at 460/560-point widths in light and dark appearances. Captures were visually inspected, including the recovery dialog.
- Supporting text contrast measured approximately 7.0:1 in light appearance and 7.86:1 in dark appearance.
- Six release-tool tests passed; unsigned arm64 app bundle built with its icon resource.
- Packaged-app smoke test passed data adoption, private pairing, window-close persistence, restart, and clean Quit using an isolated synthetic development runtime and seed data.
- Source/copy/icon and diff privacy/whitespace passes completed. Fixtures are synthetic.

## Limits and rollout

Live Touch ID/Mac password interaction was not manually exercised; automated authorization tests inject outcomes. This is not a full accessibility certification. Browser automation was unavailable. The smoke runtime was a development fixture, not a published release archive.

The supporting core account changes must be released before downloaded runtimes can offer recovery or chosen-username setup. Older runtimes show a recovery update explanation and retain existing bootstrap behavior.
