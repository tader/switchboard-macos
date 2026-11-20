# Release automation and Apple signing

Merge the app changes and workflows into `main` first. Release Please opens a version/changelog PR. Merging that PR creates the app tag and GitHub Release; the same workflow then calls `release-build.yml` using the emitted tag. This works with the built-in GitHub token, whose release/tag events do not otherwise start additional workflows.

Both Apple Silicon and Intel jobs download one selected compatible core release, validate its runtime assets, run the Swift tests with those assets, build an optimized app and run the packaged-app smoke. Each successful architecture uploads its ZIP to the app release. Check both jobs before announcing the release: a failed job can leave the release with only the other architecture's asset.

`CORE_RELEASE_TAG` is an optional repository Actions variable to pin the compatible core version. Without it, the build selects the latest stable core release once for both architectures. Missing or incompatible published assets fail the build. The app still discovers server versions independently at runtime.

`MACOS_SIGN_RELEASES=true` enables signing for automatic releases. Until configured, builds are clearly named `*-unsigned.zip`. Once enabled, missing credentials or failed signing/notarization fails the job; it never falls back to an unsigned upload. Signing uses a temporary owner-only keychain, Developer ID Application identity, hardened runtime and secure timestamp. The script requires Apple's explicit Accepted status, staples and validates the ticket, checks the signature and Gatekeeper assessment, then archives the stapled app.

## Prepare Apple credentials

1. In Keychain Access, open **My Certificates** and locate **Developer ID Application: Your Name (TEAMID)**. Expand it and confirm a private key is attached. Apple Development and Mac App Distribution certificates cannot be used for this direct-download workflow. If your certificate is on another Mac, export it there with its private key; a downloaded `.cer` alone is insufficient.
2. Select the identity and export it as a password-protected `.p12` outside this repository. If needed, create a Developer ID Application certificate through the Account Holder in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list), using a certificate signing request generated on your Mac. Importing the downloaded `.cer` on that same Mac pairs it with the private key.
3. In [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api), go to **Users and Access → Integrations → App Store Connect API → Team Keys**. The Account Holder may first need to request API access. Generate a dedicated team key with the **Developer** role, download the `.p8` once, and record the **Key ID** and **Issuer ID**. This script expects a team key; individual keys use a different authentication format. No App Store listing is needed for the direct-download app.
4. Store the `.p12`, its password and the `.p8` securely outside the source checkout. Do not paste them into chat, commit them or attach them to an issue.

## Configure GitHub

Install GitHub CLI and sign in with access to this repository's Actions secrets and variables. For a fine-grained token this needs repository **Secrets: read/write** and **Variables: read/write**. For a classic token use `repo` for a private repository. Organization restrictions may require additional authorization.

Run from this checkout, replacing the example paths and identifiers:

```sh
python3 scripts/configure-signing.py \
  --certificate "$HOME/secure/switchboard-developer-id.p12" \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-key "$HOME/secure/AuthKey_KEYID.p8" \
  --key-id KEYID \
  --issuer ISSUER-UUID
```

The command prompts privately for the export password, uploads six encrypted repository secrets over stdin, and only then enables `MACOS_SIGN_RELEASES`. It prints secret names, never their values. The Issuer ID is the App Store Connect API UUID, not the Developer Team ID. The GitHub UI alternative is **Settings → Secrets and variables → Actions**:

| Repository secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE` | Base64-encoded `.p12` including private key |
| `DEVELOPER_ID_PASSWORD` | `.p12` export password |
| `SIGNING_IDENTITY` | Full Developer ID Application identity name |
| `NOTARY_KEY` | Entire `.p8` file, with header/footer and newlines |
| `NOTARY_KEY_ID` | API Key ID |
| `NOTARY_ISSUER` | Team API Issuer ID |

After all six secrets are saved, set the repository Actions **variable** `MACOS_SIGN_RELEASES` to `true`. Keep the default workflow permissions and branch protection rules; no personal token is needed by Release Please just to start the reusable build.

## Verify the first signed release

Once the workflow is on `main` and an app release tag exists, run **Actions → Native release build → Run workflow**. Supply the app tag, optionally a compatible core tag, and select **sign**. This uploads signed assets to that release, replacing same-name files. An older app tag must already contain the updated scripts to exercise the new signing behavior; create the first release from the updated code.

Download each ZIP, extract the app, and check:

```sh
codesign --verify --strict /path/to/Switchboard.app
xcrun stapler validate /path/to/Switchboard.app
spctl --assess --type execute --verbose /path/to/Switchboard.app
```

Test opening the downloaded app on a Mac as well. Successful local syntax and mocked tests do not validate a real certificate or Apple's service. After the first success, merging later Release Please PRs builds, signs, notarizes and attaches both apps automatically.

If Apple returns Invalid, use the submission ID printed in the workflow with `xcrun notarytool log` and the same key credentials to retrieve the diagnostic log locally. A timeout may leave a submission processing at Apple; inspect its status before retrying. Rerun failed jobs or manually rerun the build for the existing tag after fixing credentials. To stop signing explicitly, set `MACOS_SIGN_RELEASES=false`; automatic builds then publish unsigned development archives again.

The separately downloaded server runtime has its own distribution/signing requirements. Notarizing the native app does not notarize those runtime assets.

References: [Release Please outputs and token behavior](https://github.com/googleapis/release-please-action), [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Command-line notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
