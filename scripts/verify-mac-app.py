#!/usr/bin/env python3
"""Verify the local bundle without opening the application or receiver."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
app = ROOT / 'Codex Drop.app'
resources = app / 'Contents/Resources'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CodexDropProjectRoot'] == str(ROOT), 'Incorrect canonical project'
assert info['LSUIElement'] is True
assert info['NSBonjourServices'] == ['_codexshot._tcp']
assert info['CodexDropIconSHA256'] == hashlib.sha256((ROOT / 'assets/CodexDrop-icon.png').read_bytes()).hexdigest()
assert Path(info['CodexDropPythonExecutable']).is_file(), 'Rebuild with an installed Python runtime'
for private in ('receiver-data', 'pairing-code.txt', '*.log'):
    assert not list(app.rglob(private)), f'Private runtime file in bundle: {private}'
for name in ('MacAttachmentReceiver', 'ReceiverPairing', 'CodexDrop.icns', 'receiver/mac_receiver.py', 'receiver/lan_receiver.py'):
    assert (resources / name).is_file(), f'Missing resource {name}'
for name, digest in json.loads((resources / 'BuildManifest.json').read_text()).items():
    assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest, f'Rebuild required after source change: {name}'
for executable in (app, resources / 'MacAttachmentReceiver', resources / 'ReceiverPairing', app / 'Contents/MacOS/CodexDrop'):
    result = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(executable)], capture_output=True, text=True, check=True)
    assert 'TeamIdentifier=YOUR_TEAM_ID' in result.stderr, f'Unexpected team for {executable.name}'
    print(f'{executable.name}: Team YOUR_TEAM_ID')
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('Bundle inspection passed: current source hashes, canonical data root, private files excluded, icon, Python runtime, resources, nested signatures.')
