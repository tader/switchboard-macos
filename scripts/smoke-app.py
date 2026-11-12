#!/usr/bin/env python3
"""Runs an isolated, relocated .app against a prepared runtime and synthetic seed data."""
import argparse, json, pathlib, shutil, socket, subprocess, tempfile, urllib.request
p=argparse.ArgumentParser();p.add_argument('--app',required=True);p.add_argument('--runtime',required=True);p.add_argument('--seed-data',required=True);a=p.parse_args()
root=pathlib.Path(tempfile.mkdtemp(prefix='switchboard-app-smoke-')).resolve()
app=root/'Switchboard.app';shutil.copytree(a.app,app);data=root/'data';shutil.copytree(a.seed_data,data)
# Seed is stopped, synthetic test data. Stale metadata is not copied into ownership checks.
(data/'.server-lock').unlink(missing_ok=True)
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
settings={'dataPath':str(data),'statePath':str(root/'updater'),'host':'127.0.0.1','port':port,'browserURL':f'http://127.0.0.1:{port}','startServer':True,'configured':True,'runtimePath':str(pathlib.Path(a.runtime).resolve())}
file=root/'settings.json';file.write_text(json.dumps(settings));file.chmod(0o600)
report=root/'result.json'
process=subprocess.run([str(app/'Contents/MacOS/SwitchboardMenu'),'--settings-file',str(file),'--show-settings','--appearance','dark','--window-width','460','--smoke-report',str(report)],timeout=130,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
assert process.returncode==0
result=json.loads(report.read_text());assert result['passed'] and result['closedWindowKeptRunning'] and result['quitStoppedOwnedProcesses'],result
try:urllib.request.urlopen(settings['browserURL']+'/readyz',timeout=1)
except Exception:pass
else:raise AssertionError('Server survived normal app quit')
print('PASS: relocated packaged .app, adopted data, private pairing, settings close keeps serving, restart, normal Quit stops server/updater')
print('Artifacts: '+str(root))
