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

Choose **Updates** or **Check for Updates** in Settings, then select a version and choose **Install / Reinstall** or **Install Latest Stable**. These actions do not require a running server or pairing. Prepared runtime assets must be published for the app’s architecture. Installation downloads fresh files, checks a disposable database copy, preserves a full data snapshot, and leaves the server stopped. Enable **Include prereleases** to see prereleases. **Cancel** is available during download and preparation; selection commits finish before Quit.

Backups and the owner-only `journal.json`, `history/` and `last-success.json` are in your updater folder; **Show Logs** opens that folder. Keep independent off-device backups of the entire data folder and updater folder while stopped. Include `secret.key`, the database, installed extensions, extension state and browser profiles together. Snapshots contain credentials; keep them private and leave room for full copies.

Before normal operation opens, startup failure automatically restores the complete snapshot and previous runtime. After opening, automatic restoration is disabled because it could discard new writes or repeat external actions. If Settings shows `recovery-required`, stop the app and preserve both current folders before making a recovery decision. The journal identifies the matching previous runtime and snapshot. Restore a complete snapshot to a new data folder, then select that folder while stopped; retain the failed data and original journal. Select a compatible runtime using the recorded `current.json` release pointer only as an explicit owner recovery step, and archive the active journal after recording that decision. Never combine a database with another snapshot's encryption key. External effects cannot be undone by restoring local files.

The app does not update its own binary in version one. Install a new native app release separately; server updates use the managed updater.

## Build locally

Run `just release` to build for this Mac, or `just release arm64` / `just release x86_64`. Swift and just are required. The optimized unsigned app is `.dist/<arch>/Switchboard.app`; the versioned unsigned ZIP is in `.dist/`.

## Install or repair without a running server

Open Settings → Server updates and choose **Check for Updates**. Select a version and choose **Install / Reinstall**, or **Install Latest Stable**. Enable **Include prereleases** to select a published prerelease. Releases require compatible prepared runtime assets. Use **More Versions** for older releases.

These controls work without pairing or a running Switchboard. **Stop and Install** stops the owned server first. Installation leaves the server stopped. Reinstallation downloads a fresh runtime, including the architecture required by the app, and preserves the old runtime. Existing data is backed up under the updater folder and migrations are checked against a disposable database copy; incompatible downgrades are refused. Start Switchboard separately when ready. Native installation does not automatically restore data after a failed Start; preserve the current data and backups before deciding on recovery.

If runtime metadata is missing, incompatible, or damaged, choose another release or reinstall. An active server lease or unresolved updater recovery journal must be resolved before runtime selection; the app never deletes those records to bypass recovery.

If installation reports **A server lock remains**, choose **Recover Server Lock…** in Settings → Server updates. The app checks the server and updater’s exclusive SQLite leases, then moves the advisory `.server-lock` record into the updater folder’s owner-only `recovered-locks/` directory. This also handles malformed records, renamed hosts, and reused process IDs. It does not signal a process or delete the lease databases. Recovery is refused while either lease is held; stop the owning Switchboard instance first. After recovery, retry installation or Start.

Installation snapshots preserve symbolic links whose targets stay inside the data folder, rebasing absolute internal links so the backup remains usable if the original folder moves. Chromium’s transient `SingletonLock`, `SingletonCookie`, and `SingletonSocket` links are omitted from snapshots; the original links are left untouched. Persistent links outside the data folder are refused with the relative path of the offending link: move the target inside the data folder before retrying. Folder relocation retains its separate restriction on symbolic links.

## Release automation

Merging a Release Please PR starts native builds for Apple Silicon and Intel and attaches the compiled app ZIPs to that GitHub Release. Signing and notarization are enabled after configuring Apple credentials. See the [release maintainer setup](development/releases/README.md) for certificate export, API key creation, GitHub Secrets and first-release verification.
