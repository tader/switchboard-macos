# Component release tag publication

The 0.3.0 release completed Developer ID signing and notarization for both architectures but failed before asset upload: the feed publisher only accepted bare v-prefixed tags, while Release Please emits component-prefixed tags.

The regression test now generates and verifies real signed feeds for both tag formats and asserts exact version-specific download URLs. It reproduced the rejection before the fix. The publisher extracts the semantic version for bundle/archive identity and retains the full tag in download URLs; prereleases and unrelated component tags remain rejected.

A manual publication retry can use the updated workflow revision's tooling with the original tagged app. Tags remain unchanged, and signing/notarization plus key/feed/archive verification remain mandatory.
