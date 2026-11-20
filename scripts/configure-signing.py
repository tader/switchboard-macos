#!/usr/bin/env python3
"""Upload local Apple signing material to GitHub Actions without printing secrets."""
import argparse
import base64
import getpass
import subprocess
from pathlib import Path


def validate_identity(identity):
    if not identity.startswith("Developer ID Application:"):
        raise ValueError(
            "Direct-download releases require a Developer ID Application certificate. "
            "Apple Development and Apple Distribution certificates cannot be used. "
            "Create a Developer ID Application certificate, export it with its private key "
            "as .p12, and pass its full name to --identity."
        )


def configure(args, password):
    validate_identity(args.identity)
    certificate = base64.b64encode(args.certificate.expanduser().read_bytes()).decode()
    key = args.notary_key.expanduser().read_text()
    if not certificate or "-----BEGIN PRIVATE KEY-----" not in key:
        raise ValueError("Supply a .p12 certificate export and a .p8 private key")
    if not password:
        raise ValueError("The certificate export must have a password")
    # Values travel over stdin, never command arguments or temporary plaintext files.
    secrets = {
        "DEVELOPER_ID_CERTIFICATE": certificate,
        "DEVELOPER_ID_PASSWORD": password,
        "SIGNING_IDENTITY": args.identity,
        "NOTARY_KEY": key,
        "NOTARY_KEY_ID": args.key_id,
        "NOTARY_ISSUER": args.issuer,
    }
    for name, value in secrets.items():
        subprocess.run(["gh", "secret", "set", name, "--repo", args.repo], input=value, text=True, check=True)
        print("Configured", name)
    # Set last: a failed upload never turns on signing for an unconfigured repo.
    subprocess.run(["gh", "variable", "set", "MACOS_SIGN_RELEASES", "--repo", args.repo, "--body", "true"], check=True)
    print("Automatic signed releases enabled. Run the release workflow to validate with Apple.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="tader/switchboard-macos")
    parser.add_argument("--certificate", type=Path, required=True, help="Password-protected .p12 including the private key")
    parser.add_argument("--notary-key", type=Path, required=True, help="App Store Connect Team API .p8 key")
    parser.add_argument("--identity", required=True, help="Full Developer ID Application identity from Keychain Access")
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True, help="Team API issuer UUID, not Apple Developer Team ID")
    args = parser.parse_args()
    try:
        validate_identity(args.identity)
        configure(args, getpass.getpass("Certificate .p12 export password: "))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
