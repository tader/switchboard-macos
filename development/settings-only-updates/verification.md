# Settings-only update controls

Removed both update entries and their unused selectors from the menu-bar menu. Settings remains available. General Settings now presents Mac app and Server update controls in equal, top-aligned columns under Updates, separated by a native divider.

Each column has a single concise description. Controls retain contextual accessible names even though their visible labels are shorter. Existing update preferences, signing, installation, progress, pinning and error handling are unchanged. Installation consequences remain visible beside their relevant actions. README navigation and control labels match the view.

Validation: all 34 Swift tests passed against published core runtime assets. The expanded UI render check passed again after adding the unavailable state. Light/dark captures at 460/560 points cover checking, available updates, up-to-date, pinned, offline and unavailable states; the narrow available/offline/unavailable layouts were visually inspected for wrapping and overflow. Existing readable colors were retained. Menu removal was checked in source. The unsigned arm64 app built and its isolated packaged-app smoke check passed data adoption, pairing, window-close persistence, restart and clean Quit.

A source copy/icon pass and diff/privacy review were completed using generic fixtures. Live keyboard/VoiceOver operation was not manually exercised; these checks do not establish full accessibility conformance.
