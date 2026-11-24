#!/usr/bin/env python3
"""Verify update packaging with disposable keys. No production key is read or uploaded."""
import base64, importlib.util, os, pathlib, plistlib, shutil, subprocess, tempfile, unittest, xml.etree.ElementTree as ET
ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('publisher', ROOT / 'scripts/publish-appcast.py')
publisher = importlib.util.module_from_spec(spec); spec.loader.exec_module(publisher)

class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='synthetic-app-updates-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / 'Assets').mkdir(); (self.root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/sparkle-public-key.swift', self.root / 'scripts/sparkle-public-key.swift')
        self.key = base64.b64encode(os.urandom(32)).decode()
        self.public = subprocess.run(['swift', str(ROOT / 'scripts/sparkle-public-key.swift')], input=self.key, text=True, capture_output=True, check=True).stdout.strip()
        (self.root / 'Assets/update-public-key.txt').write_text(self.public)
        publisher.ROOT = self.root
        self.addCleanup(setattr, publisher, 'ROOT', ROOT)
        self.directory = self.root / 'release'; self.directory.mkdir()
        self.tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'

    def test_prereleases_and_invalid_keys_are_rejected(self):
        for tag in ['v1.0.0-dev.1', 'switchboard-macos-v1.0.0-dev.1', 'other-v1.0.0', 'v1.0', '../escape']:
            with self.assertRaises(ValueError): publisher.generate('arm64', tag, self.directory, self.tools, self.key)
        for key in ['', 'invalid', base64.b64encode(bytes(16)).decode()]:
            with self.assertRaises(ValueError): publisher.generate('arm64', 'v1.0.0', self.directory, self.tools, key)

    def test_wrong_signing_identity_is_rejected(self):
        other = base64.b64encode(os.urandom(32)).decode()
        with self.assertRaisesRegex(ValueError, 'does not match'):
            publisher.generate('arm64', 'v1.0.0', self.directory, self.tools, other)

    def test_real_signed_feed_and_archive_verify_and_reject_tampering(self):
        arch = os.environ.get('SWITCHBOARD_TEST_APP_ARCH', os.uname().machine)
        source = ROOT / f'.dist/{arch}/Switchboard.app'
        if not source.exists() or not self.tools.exists(): self.skipTest('Build the app before exercising real Sparkle tools')
        app = self.root / 'Switchboard.app'
        subprocess.run(['/usr/bin/ditto', str(source), str(app)], check=True)
        info_file = app / 'Contents/Info.plist'
        info = plistlib.loads(info_file.read_bytes())
        self.assertFalse(info['SUAppUpdatesEnabled'], 'Unsigned bundles must never enable live app updates')
        self.assertTrue(info['SUEnableAutomaticChecks']); self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertFalse(info['SUAllowsAutomaticUpdates']); self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertIn(f'appcast-{arch}.xml', info['SUFeedURL'])
        info.update(SUAppUpdatesEnabled=True, SUPublicEDKey=self.public, CFBundleVersion='1.0.1', CFBundleShortVersionString='1.0.1')
        info_file.write_bytes(plistlib.dumps(info))
        # Ad-hoc seal for local feed tests only; production uses the notarization pipeline.
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        archive = self.directory / f'Switchboard-1.0.1-{arch}.zip'
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
        for tag in ['v1.0.1', 'switchboard-macos-v1.0.1']:
            feed = publisher.generate(arch, tag, self.directory, self.tools, self.key)
            enclosure = ET.parse(feed).find('./channel/item/enclosure')
            self.assertEqual(enclosure.get('url'), f'https://github.com/tader/switchboard-macos/releases/download/{tag}/{archive.name}')
        self.assertTrue(feed.exists())
        enclosure = ET.parse(feed).find('./channel/item/enclosure')
        signature = enclosure.get(publisher.SPARKLE + 'edSignature')
        archive.write_bytes(archive.read_bytes() + b'synthetic-tamper')
        result = subprocess.run([str(self.tools / 'sign_update'), '--verify', '--ed-key-file', '-', str(archive), signature], input=self.key, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        text = feed.read_text(); feed.write_text(text.replace('<title>', '<title>synthetic-tamper', 1))
        result = subprocess.run([str(self.tools / 'sign_update'), '--verify', '--ed-key-file', '-', str(feed)], input=self.key, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__': unittest.main()
