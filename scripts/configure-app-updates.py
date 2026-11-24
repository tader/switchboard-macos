#!/usr/bin/env python3
"""Create a dedicated Sparkle Keychain key and configure GitHub without printing secrets."""
import argparse, base64, json, os, pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent

def configure(tools, repo, account):
    existing = json.loads(subprocess.check_output(['gh', 'secret', 'list', '--repo', repo, '--json', 'name'], text=True))
    if any(row['name'] == 'SPARKLE_PRIVATE_KEY' for row in existing):
        raise ValueError('SPARKLE_PRIVATE_KEY already exists; refusing to replace an update signing identity')
    command = str(tools / 'generate_keys')
    subprocess.run([command, '--account', account], check=True, capture_output=True)
    public = subprocess.check_output([command, '--account', account, '-p'], text=True).strip()
    if len(base64.b64decode(public, validate=True)) != 32:
        raise ValueError('Sparkle did not return a valid public key')
    with tempfile.TemporaryDirectory(prefix='switchboard-update-key-') as temporary:
        export = pathlib.Path(temporary) / 'private-key'
        subprocess.run([command, '--account', account, '-x', str(export)], check=True, capture_output=True)
        export.chmod(0o600)
        secret = export.read_bytes()
        if len(base64.b64decode(secret.strip(), validate=True)) != 32:
            raise ValueError('Expected the current Sparkle seed format')
        subprocess.run(['gh', 'secret', 'set', 'SPARKLE_PRIVATE_KEY', '--repo', repo], input=secret, check=True, capture_output=True)
    (ROOT / 'Assets/update-public-key.txt').write_text(public + '\n')
    print('Update signing configured; only the public key was written to Assets.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--tools', type=pathlib.Path, default=pathlib.Path('.build/artifacts/sparkle/Sparkle/bin'))
    parser.add_argument('--repo', default='tader/switchboard-macos')
    parser.add_argument('--account', default='nl.tader.Switchboard')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        configure(args.tools.resolve(), args.repo, args.account)
    except (ValueError, subprocess.CalledProcessError) as error:
        # Subprocess output is deliberately withheld: exported signing material must never reach logs.
        raise SystemExit(str(error) if isinstance(error, ValueError) else 'Update signing setup failed; no private material was printed.')
