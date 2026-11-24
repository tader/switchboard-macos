#!/usr/bin/env python3
"""Configuration safety tests: all Keychain/GitHub operations are mocked."""
import base64, importlib.util, json, pathlib, subprocess, tempfile, unittest
from unittest.mock import patch
ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('configuration', ROOT / 'scripts/configure-app-updates.py')
configuration = importlib.util.module_from_spec(spec); spec.loader.exec_module(configuration)

class ConfigurationTests(unittest.TestCase):
    def test_existing_key_is_never_overwritten(self):
        with patch.object(configuration.subprocess, 'check_output', return_value=json.dumps([{'name':'SPARKLE_PRIVATE_KEY'}])), patch.object(configuration.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'refusing to replace'):
                configuration.configure(pathlib.Path('/synthetic/tools'), 'example/app', 'synthetic')
            run.assert_not_called()

    def test_private_key_uses_stdin_only_and_temporary_export_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); (root / 'Assets').mkdir()
            public = base64.b64encode(bytes(32)).decode()
            secret = base64.b64encode(bytes(range(32)))
            exports = []
            def command(args, **kwargs):
                if '-x' in args:
                    export = pathlib.Path(args[-1]); export.write_bytes(secret); exports.append(export)
                if args[:3] == ['gh', 'secret', 'set']:
                    self.assertEqual(kwargs['input'], secret)
                    self.assertNotIn(secret.decode(), ' '.join(args))
                return subprocess.CompletedProcess(args, 0)
            with patch.object(configuration, 'ROOT', root), patch.object(configuration.subprocess, 'check_output', side_effect=['[]', public]), patch.object(configuration.subprocess, 'run', side_effect=command):
                configuration.configure(pathlib.Path('/synthetic/tools'), 'example/app', 'synthetic')
            self.assertEqual((root / 'Assets/update-public-key.txt').read_text().strip(), public)
            self.assertTrue(exports); self.assertFalse(exports[0].exists())

if __name__ == '__main__': unittest.main()
