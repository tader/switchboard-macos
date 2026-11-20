#!/usr/bin/env python3
"""Exercise credential setup and signing failure paths without Apple credentials."""
import argparse
from contextlib import redirect_stdout
import io
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("configure_signing", ROOT / "scripts/configure-signing.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class CredentialSetupTests(unittest.TestCase):
    def test_values_use_stdin_and_enable_only_after_all_uploads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cert, key = root / "identity.p12", root / "key.p8"
            cert.write_bytes(b"synthetic certificate")
            key.write_text("-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----")
            args = argparse.Namespace(certificate=cert, notary_key=key, identity="Developer ID Application: Synthetic (TEST)", key_id="SYNTHETIC", issuer="synthetic-issuer", repo="example/app")
            with patch.object(setup.subprocess, "run") as run, redirect_stdout(io.StringIO()):
                setup.configure(args, "synthetic-password")
                calls = run.call_args_list
                self.assertEqual(len(calls), 7)
                self.assertEqual(calls[0].kwargs["input"], base64.b64encode(cert.read_bytes()).decode())
                self.assertEqual(calls[3].kwargs["input"], key.read_text())
                for call in calls[:6]:
                    self.assertEqual(call.args[0][1:3], ["secret", "set"])
                    self.assertNotIn(call.kwargs["input"], call.args[0])
                self.assertEqual(calls[-1].args[0][1:4], ["variable", "set", "MACOS_SIGN_RELEASES"])
            with patch.object(setup.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "gh")) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    setup.configure(args, "synthetic-password")
                self.assertEqual(run.call_count, 1)


class SigningTests(unittest.TestCase):
    def exercise(self, status="Accepted", stapler_failure=False, notary_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bin"
            binary.mkdir()
            shim = binary / "shim"
            shim.write_text("#!" + sys.executable + "\n" + SHIM)
            shim.chmod(0o700)
            for command in ["security", "uuidgen", "codesign", "ditto", "xcrun", "spctl"]:
                (binary / command).symlink_to(shim)
            (root / ".dist/arm64/Switchboard.app").mkdir(parents=True)
            unsigned = root / ".dist/Switchboard-1.0.0-arm64-unsigned.zip"
            unsigned.touch()
            (root / "version.json").write_text('{"version":"1.0.0"}')
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"], MOCK_LOG=str(log), MOCK_STATUS=status,
                       MOCK_STAPLER_FAILURE=str(int(stapler_failure)), MOCK_NOTARY_FAILURE=str(int(notary_failure)),
                       CERTIFICATE=base64.b64encode(b"synthetic certificate").decode(), CERTIFICATE_PASSWORD="synthetic-password",
                       SIGNING_IDENTITY="Developer ID Application: Synthetic (TEST)", NOTARY_KEY="synthetic-key", NOTARY_KEY_ID="SYNTHETIC", NOTARY_ISSUER="synthetic-issuer")
            result = subprocess.run(["bash", str(ROOT / "scripts/sign-release.sh"), "arm64"], cwd=root, env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            deleted = [call[-1] for call in calls if call[:2] == ["security", "delete-keychain"]]
            self.assertEqual(len(deleted), 1)
            self.assertFalse(Path(deleted[0]).parent.exists(), "Temporary credentials must be removed")
            if status == "Accepted" and not stapler_failure and not notary_failure:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(unsigned.exists())
                self.assertIn(["xcrun", "stapler", "validate", ".dist/arm64/Switchboard.app"], calls)
                self.assertIn(["spctl", "--assess", "--type", "execute", ".dist/arm64/Switchboard.app"], calls)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(unsigned.exists())
                self.assertFalse(any(call[0] == "spctl" for call in calls))
                if status != "Accepted" or notary_failure:
                    self.assertFalse(any(call[:2] == ["xcrun", "stapler"] for call in calls))

    def test_accepted_submission_is_stapled_and_verified(self):
        self.exercise()

    def test_invalid_submission_never_reaches_stapling(self):
        self.exercise(status="Invalid")

    def test_notary_command_failure_cleans_credentials(self):
        self.exercise(notary_failure=True)

    def test_stapler_failure_does_not_finish_archive(self):
        self.exercise(stapler_failure=True)


SHIM = r'''import json, os, pathlib, sys
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps([command, *args]) + "\n")
if command == "uuidgen":
    print("synthetic-keychain-password")
elif command == "security" and args == ["list-keychains", "-d", "user"]:
    print('"/synthetic/login.keychain-db"')
elif command == "ditto":
    pathlib.Path(args[-1]).touch()
elif command == "xcrun" and args[:2] == ["notarytool", "submit"]:
    if os.environ["MOCK_NOTARY_FAILURE"] == "1":
        sys.exit(1)
    print(json.dumps({"id": "synthetic-submission", "status": os.environ["MOCK_STATUS"]}))
elif command == "xcrun" and args[0] == "stapler" and os.environ["MOCK_STAPLER_FAILURE"] == "1":
    sys.exit(1)
'''

if __name__ == "__main__":
    unittest.main()
