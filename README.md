# Switchboard for macOS

A menu bar manager for a local Switchboard server. Requires macOS 14 or later on Apple Silicon or Intel. The app downloads a prepared server runtime; Node, Git, npm and Xcode are not required on your Mac.

Current builds are **unsigned development builds**. No production Developer ID or notarization identity is configured. The optional release workflow supports signing and notarization once those credentials are supplied. Do not treat development artifacts as production-signed releases.

## Set up

Download the archive for your Mac from this repository's releases, extract `Switchboard.app`, and place it in Applications. Open the app and review the folders and port in Settings. Choose **Set Up Switchboard**. The app downloads and verifies a compatible stable core runtime, starts the server, and automatically opens its one-time administrator setup page in your default browser.

Create your administrator password in the browser. The app detects completion and pairs the updater automatically. No password or token needs to be entered in the native app. Runtime availability depends on the core release finishing publication; if it is not ready, retry after that release's assets have appeared.

Defaults:

| Setting | Default |
| --- | --- |
| Data | `~/.switchboard` |
| Updater state and backups | `~/Library/Application Support/Switchboard/Updater` |
| Listen address | `127.0.0.1` |
| Port | `8770` |
| Browser URL | `http://127.0.0.1:8770` |
| Updates | Stable core releases |
| Open app at login | Off |
| Start server when app opens | On after setup |

Existing compatible data is adopted without replacing its database or resetting its administrator. Stop any existing server and disable its previous automatic launcher before adopting that folder. An occupied port or an active data lease is an error; the app does not kill an unrelated process or start a second server on the same data.

## Menu bar

Left-click the icon to open a running server in your default browser. If stopped or installing, left-click opens setup/settings. Right-click for **Open**, **Start/Stop**, **Restart**, **Updates**, **Settings**, **Show Logs** and **Quit**.

Closing Settings leaves the app and server running. **Quit** gracefully stops the app's own server and updater. During a server update it waits for cutover/recovery to finish before quitting. If the app crashes, pipe closure stops the supervisor and its server; if the supervisor crashes, IPC disconnection stops its server. A subsequent launch uses the recovery journal rather than replaying an interrupted deployment.

When a connection reports an explicit terminal sign-in failure, the menu bar shows an accessible count. **Sign in to connections** opens the local connections page. Offline services and timeouts do not create sign-in alerts. The app receives only aggregate counts and never polls providers for health.

## Settings and startup

Stop the server before changing paths, listen address, port or browser URL. Paths are resolved through symbolic links; the data and updater folders cannot overlap. If relocating existing data or updater state, choose **Copy and verify**. The original folders are retained. The app verifies file contents, rebases known release/journal paths in the copied state and discards stale process metadata before selecting the copy. External symbolic links are refused for relocation.

The listen address can be a local IP address or `localhost`. Wildcard `0.0.0.0` and `::` expose the server to other interfaces while the manager uses loopback control. Use an appropriate firewall when choosing a network-facing address. The browser URL is configurable independently.

**Open app at login** uses macOS Login Items. It is independent of **Start server when the app opens**. The displayed status comes from macOS and may say **Approval required**; use **Open Login Items Settings** to complete approval. Closing the app's Settings window does not change either preference.

Settings are owner-readable only. The manager keeps its narrow updater credential in memory, paired through private parent-child IPC; it persists no native credential. Bootstrap links, updater tokens and passwords are excluded from native logs. If future native credentials are required they must be stored in Keychain.

## Updates, backups and recovery

Choose **Updates** or **Check for Updates** in Settings, then **Install Update** when a verified stable release is available. The core release must contain a compatible prepared runtime for your architecture. The updater downloads and checks it without building source on your Mac. It retains the previous runtime and makes a full data snapshot before cutover. **Cancel Update** is available while queued or preparing.

Backups and the owner-only `journal.json`, `history/` and `last-success.json` are in your updater folder; **Show Logs** opens that folder. Keep independent off-device backups of the entire data folder and updater folder while stopped. Include `secret.key`, the database, installed extensions, extension state and browser profiles together. Snapshots contain credentials; keep them private and leave room for full copies.

Before normal operation opens, startup failure automatically restores the complete snapshot and previous runtime. After opening, automatic restoration is disabled because it could discard new writes or repeat external actions. If Settings shows `recovery-required`, stop the app and preserve both current folders before making a recovery decision. The journal identifies the matching previous runtime and snapshot. Restore a complete snapshot to a new data folder, then select that folder while stopped; retain the failed data and original journal. Select a compatible runtime using the recorded `current.json` release pointer only as an explicit owner recovery step, and archive the active journal after recording that decision. Never combine a database with another snapshot's encryption key. External effects cannot be undone by restoring local files.

The app does not update its own binary in version one. Install a new native app release separately; server updates use the managed updater.
