"""Private macOS runtime storage; atomic legacy migration, never identity rotation."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import tempfile

DEFAULT_DATA = Path.home() / 'Library' / 'Application Support' / 'Codex Drop'
MARKER = '.storage-migration.json'

def _directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError('Runtime storage must be a real directory owned by this account')

def _tree(path):
    _directory(path)
    for child in path.iterdir():
        info = child.lstat()
        if info.st_uid != os.getuid():
            raise RuntimeError('Runtime storage contains a file owned by another account')
        if stat.S_ISDIR(info.st_mode): _tree(child)
        elif not stat.S_ISREG(info.st_mode):
            raise RuntimeError('Runtime storage contains a link or special file; migration refused')

@contextlib.contextmanager
def _lock(path):
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError('Unsafe runtime lock file')
        try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('Codex Drop or its receiver is running; close it before migrating data') from error
        yield
    finally: os.close(descriptor)

def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)

def _write_marker(directory, source, destination, complete=False):
    with tempfile.NamedTemporaryFile(dir=directory, delete=False) as stream:
        temporary = Path(stream.name); os.fchmod(stream.fileno(), 0o600)
        stream.write(json.dumps({'version':1,'source':str(source),'destination':str(destination),'complete':complete}).encode())
        stream.flush(); os.fsync(stream.fileno())
    try: os.replace(temporary, directory / MARKER); _sync_directory(directory)
    finally: temporary.unlink(missing_ok=True)

def _rewrite_paths(directory):
    marker = directory / MARKER
    if not marker.exists(): return
    if marker.is_symlink(): raise RuntimeError('Unsafe migration marker')
    value = json.loads(marker.read_text())
    if value.get('version') != 1 or value.get('destination') != str(directory):
        raise RuntimeError('Conflicting runtime migration marker')
    source = Path(value['source'])
    if not source.is_absolute(): raise RuntimeError('Invalid migration source')
    source = source.parent.resolve() / source.name
    database = directory / 'queue.sqlite3'
    if not database.exists():
        _write_marker(directory,source,directory,complete=True)
        return
    if database.is_symlink(): raise RuntimeError('Unsafe runtime database')
    with sqlite3.connect(database) as db:
        db.execute('BEGIN IMMEDIATE')
        def rewrite(path):
            if not path: return path
            p = Path(path)
            try: relative = p.relative_to(source / 'images')
            except ValueError:
                try:
                    relative = p.relative_to(directory / 'images')
                    if '..' in relative.parts: raise ValueError('Invalid queued image path')
                except ValueError as error: raise RuntimeError('Queue contains an unexpected image location') from error
                return str(p)
            if '..' in relative.parts: raise RuntimeError('Invalid queued image path')
            return str(directory / 'images' / relative)
        for key,path in db.execute('SELECT id,image FROM jobs').fetchall():
            updated = rewrite(path)
            if updated != path: db.execute('UPDATE jobs SET image=? WHERE id=?',(updated,key))
        for key,index,path in db.execute('SELECT batch_id,image_index,path FROM batch_images').fetchall():
            updated = rewrite(path)
            if updated != path: db.execute('UPDATE batch_images SET path=? WHERE batch_id=? AND image_index=?',(updated,key,index))
    _write_marker(directory,source,directory,complete=True)

def prepare_storage(legacy, destination=DEFAULT_DATA):
    legacy = Path(legacy).absolute(); destination = Path(destination).absolute()
    legacy = legacy.parent.resolve() / legacy.name
    destination = destination.parent.resolve() / destination.name
    if legacy == destination: raise RuntimeError('Legacy and destination directories must differ')
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _directory(destination.parent)
    with _lock(destination.parent / '.codex-drop-migration.lock'):
        if destination.exists() or destination.is_symlink():
            _directory(destination)
            if (destination/'images').exists() or (destination/'images').is_symlink():
                _directory(destination/'images')
            if (destination/'queue.sqlite3').is_symlink(): raise RuntimeError('Unsafe runtime database')
            if legacy.exists() or legacy.is_symlink():
                raise RuntimeError('Both old and new runtime storage exist; refusing to merge pairing identities')
            marker = destination/MARKER
            if marker.is_symlink(): raise RuntimeError('Unsafe migration marker')
            if marker.exists() and not json.loads(marker.read_text()).get('complete',False):
                with _lock(destination/'codex-drop-app.lock'), _lock(destination/'receiver.lock'):
                    _rewrite_paths(destination)
            os.chmod(destination,0o700)
            return destination
        if legacy.exists() or legacy.is_symlink():
            _tree(legacy)
            with _lock(legacy/'codex-drop-app.lock'), _lock(legacy/'receiver.lock'):
                _write_marker(legacy,legacy,destination)
                # Same-volume rename preserves identity and SQLite files together. If
                # cross-volume, fail with the source intact; never copy/delete silently.
                os.rename(legacy,destination)
                _sync_directory(destination.parent)
                _sync_directory(legacy.parent)
                _rewrite_paths(destination)
        else: destination.mkdir(mode=0o700)
        os.chmod(destination,0o700)
        return destination

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--legacy',type=Path,required=True)
    parser.add_argument('--destination',type=Path,default=DEFAULT_DATA)
    args=parser.parse_args()
    try: print(prepare_storage(args.legacy,args.destination))
    except (OSError,ValueError,RuntimeError,sqlite3.Error) as error:
        parser.exit(1,f'Runtime storage preparation failed: {error}\n')
