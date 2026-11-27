# Switchboard for macOS

A menu bar manager for a local Switchboard server. Requires macOS 14 or later on Apple Silicon or Intel. The app downloads a prepared server runtime; Node, Git, npm and Xcode are not required on your Mac.

The app ZIPs published on [GitHub Releases](https://github.com/tader/switchboard-macos/releases) are **Developer ID signed and notarized by Apple**, with the notarization ticket stapled to the app. Download `Switchboard-<version>-arm64.zip` for Apple Silicon or `Switchboard-<version>-x86_64.zip` for Intel. Local builds and CI artifacts labelled `unsigned` are development builds without release signing or notarization.

## Set up

Download the archive for your Mac from this repository's releases, extract `Switchboard.app`, and place it in Applications. Open the app; the recommended folders and network settings are ready to use. Choose **Set Up Switchboard**. The app downloads and verifies a compatible stable core runtime, starts the server, and automatically opens its one-time administrator setup page in your default browser.

Choose your administrator username and password in the browser. The app detects completion and pairs the updater automatically. No password or token needs to be entered in the native app. Runtime availability depends on the core release finishing publication; if it is not ready, retry after that release's assets have appeared.

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

## Account setup and password recovery

While initial setup is incomplete, **Continue Account Setup** opens the browser setup form again. New installations can choose a username; existing accounts keep theirs. If your server is too old to refresh the link, restart Switchboard to get a fresh setup link.

Near the bottom of Settings, choose **Recover Password…**, select an enabled local account, then **Authenticate & Recover**. If stopped, use **Start & Continue to Recovery…**. Your Mac requires fresh device-owner authentication, such as Touch ID or your Mac login password, before the app requests a recovery link. You enter the new Switchboard password only in your browser.

The link expires after 10 minutes and works once. Completing recovery signs the selected user out of existing browser sessions while preserving their username, role, connections and data. Disabled users and peer-shadow accounts are excluded. A server version without this capability shows an update explanation.

This feature trusts the macOS account owning the local installation to recover its users. It communicates through private parent–child pipes, not an HTTP recovery endpoint. Authentication helps protect an unlocked Mac from casual misuse; it does not protect against malware controlling the owning account or a compromised manager. Recovery links are not saved in settings or written to logs.

## Menu bar

Left-click the icon to open a ready server in your default browser. Until it is ready, left-click opens Settings. Right-click or Control-click for **Open Switchboard**, **Settings…**, **Start/Stop**, **Restart**, **Show Logs** and **Quit**. **⌘,** opens Settings while the app is active.

Closing Settings leaves the app and server running. **Quit** gracefully stops the app's own server and updater. During a server update it waits for cutover/recovery to finish before quitting. If the app crashes, pipe closure stops the supervisor and its server; if the supervisor crashes, IPC disconnection stops its server. A subsequent launch uses the recovery journal rather than replaying an interrupted deployment.

When the current ready server reports an explicit terminal sign-in failure, the monochrome menu-bar icon shows a count. The tooltip and accessible name spell out the exact count. **Sign in to connections (N)** appears first in the menu and opens the local connections page. The indicator and action clear at zero, on stop, or when current status is unavailable. Offline services and timeouts do not create sign-in alerts. The app receives only aggregate counts and never polls providers for health.

## Settings and startup

Use the always-visible **General** and **Advanced** selector. General separates the server state from account setup/readiness and connection sign-in. Advanced keeps a draft across pane changes, background refreshes and hiding the window. **Save Changes** (⌘S) validates each field and keeps the draft on failure. Starting or restarting with unsaved edits asks whether to save, use saved settings, or cancel.

Choose **Advanced** for folders, network settings, version pinning and maintenance. Stop the server before changing paths, listen address, port or browser URL. Paths are resolved through symbolic links; the data and updater folders cannot overlap. If relocating existing data or updater state, choose **Copy and verify folders when moving data**. The original folders are retained. The app verifies file contents, rebases known release/journal paths in the copied state and discards stale process metadata before selecting the copy. External symbolic links are refused for relocation.

The listen address can be a local IP address or `localhost`. Wildcard `0.0.0.0` and `::` expose the server to other interfaces while the manager uses loopback control. Use an appropriate firewall when choosing a network-facing address. The browser URL is configurable independently.

**Open app at login** uses macOS Login Items. It is independent of **Start server when the app opens**. The displayed status comes from macOS and may say **Approval required**; use **Open Login Items Settings** to complete approval. Closing the app's Settings window does not change either preference.

Settings are owner-readable only. The manager keeps its narrow updater credential in memory, paired through private parent-child IPC; it persists no native credential. Bootstrap links, updater tokens and passwords are excluded from native logs. If future native credentials are required they must be stored in Keychain.

## Updates, backups and recovery

Settings → Updates → Server follows **Stable (recommended)** by default. Choose **Development** to follow published prereleases with compatible macOS runtime assets. **Check for updates…** resolves the latest compatible release; installation starts only when you choose it. To select a particular version, open **Advanced**, enable **Pin a specific version**, and choose a release. Disable pinning to return to your channel. Download progress shows actual bytes and a percentage when the total size is available, followed by verification and installation stages. Installation preserves your data and starts the selected server automatically. Cancellation is available before the final selection commit.

Backups and the owner-only `journal.json`, `history/` and `last-success.json` are in your updater folder; **Show Logs** opens that folder. Keep independent off-device backups of the entire data folder and updater folder while stopped. Include `secret.key`, the database, installed extensions, extension state and browser profiles together. Snapshots contain credentials; keep them private and leave room for full copies.

Before normal operation opens, startup failure automatically restores the complete snapshot and previous runtime. After opening, automatic restoration is disabled because it could discard new writes or repeat external actions. If Settings shows `recovery-required`, stop the app and preserve both current folders before making a recovery decision. The journal identifies the matching previous runtime and snapshot. Restore a complete snapshot to a new data folder, then select that folder while stopped; retain the failed data and original journal. Select a compatible runtime using the recorded `current.json` release pointer only as an explicit owner recovery step, and archive the active journal after recording that decision. Never combine a database with another snapshot's encryption key. External effects cannot be undone by restoring local files.

## App updates

In Settings → Updates, **Mac app** is the menu bar app on your Mac; **Server** runs Switchboard in your browser. Both update controls live here, side by side when space permits and stacked in a narrow window.

Signed releases check GitHub for new stable macOS app releases automatically, normally once a day. You are asked before downloading and installing an update; app updates are never installed silently. Use **Check for updates…** from Settings → Updates → Mac app to check immediately. Turn off **Check automatically** if you prefer manual checks.

Installing an app update stops the owned server gracefully and waits for installation cleanup or an active server update to finish. The app then updates and reopens. Your startup preference determines whether the server starts again. Your accounts, data folders and server release preference are retained.

App updates are independent of **Server updates**, which chooses Stable, Development or a pinned server runtime. The app checks only stable releases appropriate for its own architecture. Sparkle verifies signed feeds and update archives before extraction, alongside the release's Developer ID signature and notarization. Anonymous system profiling and silent automatic installation are disabled.

Install the first signed app release containing this updater manually; older app versions cannot update themselves. Unsigned local/CI builds keep app updates disabled. If an update check fails while offline or during release publication, retry later; the installed app stays available.

## Build locally

Run `just release` to build for this Mac, or `just release arm64` / `just release x86_64`. Swift and just are required. The optimized unsigned app is `.dist/<arch>/Switchboard.app`; the versioned unsigned ZIP is in `.dist/`.

### Native checks

Run `swift test` on macOS. To export synthetic native Settings and status-button renders, run `SWITCHBOARD_UI_SNAPSHOT_DIR="$PWD/.dist/ui-review" swift test --filter SettingsDesignTests`. Fixtures isolate accounts, Keychain reads, release requests and server processes from personal data. The status-button PNGs render the actual AppKit cell in a test window; they do not verify its placement in the system menu bar.

For interactive verification, check General/Advanced navigation, retained drafts and failed saves, validation focus, ⌘S/⌘,, Login Items approval/return, recovery selection and cancellation, native menu keyboard access, and VoiceOver. Check the menu-bar count and first menu action at 0, 1 and multiple sign-ins, after stopping, and after loss of current status. Inspect 460/560-point widths in light/dark and enlarged text.

## Install or repair without a running server

Open Settings → Updates → Server and choose **Check for updates…**, then install the selected release. For older versions, open **Advanced** and enable **Pin a specific version**. Use **Load Older Versions** to browse earlier releases. **Reinstall Selected Release** is under Advanced → Maintenance.

These controls work without pairing or a running Switchboard. **Stop & Update** stops the owned server first. Installation starts the selected server automatically. Reinstallation downloads a fresh runtime, including the architecture required by the app, and preserves the old runtime. Existing data is backed up under the updater folder and migrations are checked against a disposable database copy; incompatible downgrades are refused. Native installation does not automatically restore data after a failed Start; preserve the current data and backups before deciding on recovery.

If runtime metadata is missing, incompatible, or damaged, choose another release or reinstall. An active server lease or unresolved updater recovery journal must be resolved before runtime selection; the app never deletes those records to bypass recovery.

If installation reports **A server lock remains**, choose **Recover Server Lock…** in Settings → Advanced → Maintenance. The app checks the server and updater’s exclusive SQLite leases, then moves the advisory `.server-lock` record into the updater folder’s owner-only `recovered-locks/` directory. This also handles malformed records, renamed hosts, and reused process IDs. It does not signal a process or delete the lease databases. Recovery is refused while either lease is held; stop the owning Switchboard instance first. After recovery, retry installation or Start.

Installation snapshots preserve symbolic links whose targets stay inside the data folder, rebasing absolute internal links so the backup remains usable if the original folder moves. Chromium’s transient `SingletonLock`, `SingletonCookie`, and `SingletonSocket` links are omitted from snapshots; the original links are left untouched. Persistent links outside the data folder are refused with the relative path of the offending link: move the target inside the data folder before retrying. Folder relocation retains its separate restriction on symbolic links.

## Release automation

Merging a Release Please PR builds, signs and notarizes the app for Apple Silicon and Intel, then attaches the compiled app ZIPs to that GitHub Release. Signed builds must pass notarization, ticket stapling, signature verification and Gatekeeper assessment before upload. See the [release maintainer setup](development/releases/README.md) for certificate export, API key creation, GitHub Secrets and first-release verification.

### Optional GitHub token

In **Settings → Updates**, save a GitHub personal access token to raise API limits for server release downloads. Public repositories require no additional permissions. The token stays in macOS Keychain. When a token is stored, Settings shows only **Remove Token**; remove it before entering a replacement. When no token is stored, the masked input and **Save Token** appear on the same row, with a **Create GitHub token…** link below.

The local server receives the token at its next start, exclusively as a rate-limit fallback for plugin catalog browsing and installation, including dependencies. Stop and start the server after changing the token. Server-side plugin updates and server updates do not use this token. This server behavior requires a runtime release containing installation-token support; older runtimes ignore it. The token does not create a GitHub connection.
