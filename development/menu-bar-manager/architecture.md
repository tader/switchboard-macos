# Menu bar manager

The AppKit status item owns a SwiftUI settings window. Closing the window leaves the application running. Left click opens a running server; right click shows fixed native controls. App login registration is independent of starting the server.

First launch downloads a stable prepared core runtime. The installer verifies release origin, commit, version, protocol, architecture, checksum and archive entries before selecting it. The runtime contains its own Node binary and production dependencies. No source checkout or build tool is needed by users.

The app starts a pipe-connected updater supervisor, which owns a Node IPC-connected server. The server exposes a small IPC-only local-manager interface. Browser passwords never enter the native app. Bootstrap URLs and pairing tokens are excluded from logs. No native credential is persisted: the IPC-connected supervisor keeps its narrow updater credential in memory and pairs again on the next launch. Future native secrets must use Keychain. Settings are owner-only.

The existing core updater journal owns migration rehearsals, full snapshots, cutover and pre-open rollback. Quitting during an upgrade waits for the transaction to finish. Pipe loss closes the supervisor; supervisor loss signals the owned server. Neither layer signals an unrelated process.

Release builds target macOS 14 or later on Apple Silicon and Intel. The default artifacts are explicitly unsigned development builds. The optional signing workflow requires configured Developer ID and notarization secrets. No signing credentials are available in this workspace. Native application self-update is excluded from version one.

Verification uses native AppKit/SwiftUI rendering in light/dark at 460/560 points, a relocated unsigned `.app` against a prepared runtime with synthetic data, and real browser/API enrollment. The packaged-app smoke closes Settings, confirms the server stays alive, restarts it and requests normal Quit. Quit cancels AppKit's first termination attempt while asynchronous cleanup runs, then requests termination again after owned processes exit; this avoids blocking main-actor completion callbacks in AppKit's deferred-termination loop. EOF handlers are removed immediately to prevent repeated empty reads.

CI's required architecture checks include the packaged-app smoke and depend on published compatible core runtime assets. Core artifacts must be released before the native dependent PR can pass those checks. Release Please PRs explicitly dispatch that same workflow on the verified PR head because bot-created events do not trigger normal PR workflows.

Path metadata is rebased when either data or updater state moves, including data-only relocation in the existing state folder. Process lease metadata is discarded only when copying updater state to a different folder. Cancelling an installer retains its task and busy state until detached download/extraction cleanup finishes; retries and settings edits remain blocked in that interval. Stop/Quit wait for the same completion callback, so extraction subprocesses are reaped before the app terminates. Native required CI job contexts are `Check (arm64)` and `Check (x86_64)`.
