#!/usr/bin/env python3
"""Staged installation with durable recovery, private manifest and no user-config edits."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import uuid


def atomic_json(path, value):
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out, sort_keys=True)
            out.flush(); os.fsync(out.fileno())
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def remove(path):
    if path.is_dir() and not path.is_symlink(): shutil.rmtree(path)
    elif path.exists() or path.is_symlink(): path.unlink()


def recover(record):
    for entry in reversed(record['entries']):
        target, backup = Path(entry['target']), Path(entry['backup'])
        if backup.exists():
            remove(target); os.replace(backup, target)
        elif not entry['existed']:
            remove(target)
        remove(Path(entry['stage']))


def install(sources, root, fail_after=None):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = os.open(root / '.install.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        transaction = root / 'install-transaction.json'
        if transaction.exists():
            old = json.loads(transaction.read_text())
            if old['state'] != 'committed':
                recover(old)
                if 'oldManifest' in old:
                    if old['oldManifest'] is None: remove(root / 'installation.json')
                    else: atomic_json(root / 'installation.json', json.loads(old['oldManifest']))
            else:
                for item in old['entries']:
                    remove(Path(item['backup'])); remove(Path(item['stage']))
            transaction.unlink()
        entries = []
        try:
            for source, target in sources:
                if not source.exists(): raise ValueError(f'missing installation source: {source}')
                target.parent.mkdir(parents=True, exist_ok=True)
                stage = target.parent / ('.' + target.name + '.stage-' + str(uuid.uuid4()))
                backup = target.parent / ('.' + target.name + '.backup-' + str(uuid.uuid4()))
                if source.is_dir(): shutil.copytree(source, stage)
                else: shutil.copy2(source, stage)
                entries.append(dict(stage=str(stage), backup=str(backup), target=str(target), existed=target.exists()))
            record = dict(state='prepared', entries=entries)
            atomic_json(transaction, record)
            for index, entry in enumerate(entries):
                target, backup, stage = map(Path, (entry['target'], entry['backup'], entry['stage']))
                if target.exists(): os.replace(target, backup)
                os.replace(stage, target)
                if fail_after == index + 1: raise OSError('injected install failure')
            hashes = {}
            for _, target in sources:
                for path in sorted(target.rglob('*')) if target.is_dir() else [target]:
                    if path.is_file(): hashes[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest = dict(protocolVersion=2, bridgeVersion='2.0.0-experimental', files=hashes,
                targets=[str(target) for _, target in sources])
            # Manifest is part of the same recovery transaction.
            manifest_path = root / 'installation.json'
            old_manifest = manifest_path.read_bytes() if manifest_path.exists() else None
            record['oldManifest'] = old_manifest.decode() if old_manifest else None
            atomic_json(transaction, record)
            atomic_json(manifest_path, manifest)
            record['state'] = 'committed'; atomic_json(transaction, record)
        except BaseException:
            if transaction.exists():
                record = json.loads(transaction.read_text())
                recover(record)
                if 'oldManifest' in record:
                    if record['oldManifest'] is None: remove(root / 'installation.json')
                    else: atomic_json(root / 'installation.json', json.loads(record['oldManifest']))
                transaction.unlink()
            else:
                for entry in entries: remove(Path(entry['stage']))
            raise
        for entry in entries: remove(Path(entry['backup']))
        transaction.unlink()
        return manifest
    finally: os.close(lock)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True)
    parser.add_argument('--source-app', type=Path, required=True)
    parser.add_argument('--source-skill', type=Path, required=True)
    parser.add_argument('--private', type=Path)
    args = parser.parse_args()
    home = Path.home()
    codex = Path(os.environ.get('CODEX_HOME', str(home / '.codex')))
    sources = [(args.source_app, home / 'Applications' / f'{args.app}.app'),
               (args.source_skill, codex / 'skills' / args.source_skill.name)]
    if args.private: sources.append((args.private, home / 'Applications' / 'CalendarBridgePrivate'))
    support = 'CalendarBridge' if args.app == 'CalendarBridge' else 'MailTriage'
    install(sources, home / 'Library' / 'Application Support' / support)
    print(json.dumps({'status': 'installed', 'protocolVersion': 2}))
