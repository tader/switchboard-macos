#!/usr/bin/env python3
"""Validate downloaded release fixtures and create disposable administrator data."""
import hashlib,json,pathlib,subprocess,tarfile,sys
assets=pathlib.Path(sys.argv[1]).resolve();arch=sys.argv[2];runtime=assets/'runtime';runtime.mkdir()
manifest=json.loads((assets/f'runtime-darwin-{arch}.json').read_text())
assert manifest['origin']=='tader/switchboard' and manifest['protocol']==1 and manifest['arch']==arch and manifest['platform']=='darwin'
archive=assets/f'switchboard-runtime-darwin-{arch}.tar.gz'
assert manifest['archive']==archive.name and hashlib.sha256(archive.read_bytes()).hexdigest()==manifest['sha256']
with tarfile.open(archive) as tar:
    for member in tar.getmembers():
        path=pathlib.PurePosixPath(member.name)
        assert not path.is_absolute() and '..' not in path.parts and '\\' not in member.name and (member.isfile() or member.isdir())
    tar.extractall(runtime,filter='data')
identity=json.loads((runtime/'build-info.json').read_text());assert identity['revision']==manifest['revision'] and identity['version']==manifest['version']
(runtime/'runtime.json').write_text(json.dumps(manifest))
seed=assets/'seed';seed.mkdir()
script="import {initDb,db} from './server/db.ts';import{initKey}from'./server/crypto.ts';import{createUser,setPassword}from'./server/users.ts';initKey();initDb();setPassword(createUser('admin','admin').id,'synthetic-test-password');db.close()"
import os
subprocess.run([str(runtime/'bin/node'),'--input-type=module','-e',script],cwd=runtime,env=dict(os.environ,SWITCHBOARD_DATA_DIR=str(seed)),check=True)
