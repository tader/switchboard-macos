#!/usr/bin/env python3
"""Generate and verify a signed per-architecture feed for an already signed release ZIP."""
import argparse, base64, os, pathlib, plistlib, re, shutil, subprocess, tempfile, xml.etree.ElementTree as ET, zipfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

def generate(arch, tag, directory, tools, key):
    if arch not in ('arm64', 'x86_64') or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('App updates require an architecture and stable version tag')
    if not key or len(base64.b64decode(key.strip(), validate=True)) != 32:
        raise ValueError('SPARKLE_PRIVATE_KEY must contain a base64-encoded 32-byte seed')
    public_key = (ROOT / 'Assets/update-public-key.txt').read_text().strip()
    derived = subprocess.run(['swift', str(ROOT / 'scripts/sparkle-public-key.swift')], input=key, text=True, capture_output=True, check=True).stdout.strip()
    if derived != public_key:
        raise ValueError('Update signing key does not match the bundled public key')
    version = tag[1:]
    archive = directory / f'Switchboard-{version}-{arch}.zip'
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('Switchboard.app/Contents/Info.plist'))
        if info.get('CFBundleIdentifier') != 'nl.tader.Switchboard' or info.get('CFBundleVersion') != version or info.get('SUPublicEDKey') != public_key or info.get('SUAppUpdatesEnabled') is not True:
            raise ValueError('Archive identity, version or updater configuration is invalid')
    with tempfile.TemporaryDirectory(prefix='switchboard-appcast-') as temporary:
        stage = pathlib.Path(temporary)
        shutil.copy2(archive, stage / archive.name)
        output = stage / f'appcast-{arch}.xml'
        subprocess.run([str(tools / 'generate_appcast'), '--ed-key-file', '-', '--maximum-deltas', '0',
            '--download-url-prefix', f'https://github.com/tader/switchboard-macos/releases/download/{tag}/', '-o', str(output), str(stage)], input=key, text=True, check=True)
        feed = ET.parse(output)
        enclosures = feed.findall('./channel/item/enclosure')
        if len(enclosures) != 1:
            raise ValueError('Expected exactly one architecture-specific update')
        enclosure = enclosures[0]
        if enclosure.get('url') != f'https://github.com/tader/switchboard-macos/releases/download/{tag}/{archive.name}' or int(enclosure.get('length', '0')) != archive.stat().st_size:
            raise ValueError('Feed references an unexpected archive')
        signature = enclosure.get(SPARKLE + 'edSignature')
        if not signature:
            raise ValueError('Archive signature is missing')
        for arguments in [[str(archive), signature], [str(output)]]:
            subprocess.run([str(tools / 'sign_update'), '--verify', '--ed-key-file', '-', *arguments], input=key, text=True, check=True)
        shutil.copy2(output, directory / output.name)
        return directory / output.name

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('arch', choices=['arm64', 'x86_64']); p.add_argument('--tag', required=True)
    p.add_argument('--directory', type=pathlib.Path, default=pathlib.Path('.dist'))
    p.add_argument('--tools', type=pathlib.Path, default=pathlib.Path('.build/artifacts/sparkle/Sparkle/bin'))
    a = p.parse_args()
    print(generate(a.arch, a.tag, a.directory.resolve(), a.tools.resolve(), os.environ.get('SPARKLE_PRIVATE_KEY', '')))
