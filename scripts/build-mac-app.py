#!/usr/bin/env python3
"""Build/sign the local Codex Drop app; never starts it or the receiver."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TEAM = 'YOUR_TEAM_ID'

def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)

def signing_identity():
    identities = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout
    available = set(re.findall(r'\b[0-9A-F]{40}\b', identities))
    certificates = run(['/usr/bin/security', 'find-certificate', '-a', '-c', 'Apple Development', '-p'], capture_output=True, text=True).stdout
    for certificate in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S):
        details = run(['/usr/bin/openssl', 'x509', '-noout', '-subject', '-fingerprint', '-sha1'], input=certificate, capture_output=True, text=True).stdout
        if re.search(r'\bOU\s*=\s*' + TEAM + r'\b', details):
            fingerprint = details.split('Fingerprint=')[-1].strip().replace(':', '')
            if fingerprint in available:
                return fingerprint
    raise RuntimeError(f'No valid existing Apple Development signing identity for Team {TEAM}; no credentials are created.')

def verify_team(path):
    details = run(['/usr/bin/codesign', '-d', '--verbose=4', path], capture_output=True, text=True).stderr
    if f'TeamIdentifier={TEAM}' not in details:
        raise RuntimeError(f'Incorrect signing team: {path.name}')
    run(['/usr/bin/codesign', '--verify', '--strict', path])

def main():
    icon = ROOT / 'assets/CodexDrop-icon.png'
    if not icon.is_file():
        raise RuntimeError('Missing assets/CodexDrop-icon.png')
    identity = signing_identity()
    with tempfile.TemporaryDirectory(prefix='CodexDrop-build-') as temporary:
        staging = Path(temporary)
        app = staging / 'Codex Drop.app'
        contents = app / 'Contents'
        resources = contents / 'Resources'
        executables = contents / 'MacOS'
        resources.mkdir(parents=True); executables.mkdir()
        (resources / 'receiver').mkdir()
        for name in ('mac_receiver.py', 'lan_receiver.py'):
            shutil.copy2(ROOT / 'receiver' / name, resources / 'receiver' / name)
        cache = staging / 'swift-cache'
        shared = ['/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', cache]
        run([*shared, ROOT / 'macos/ReceiverController.swift', ROOT / 'macos/AppPresentation.swift', ROOT / 'macos/CodexDropApp.swift', '-o', executables / 'CodexDrop'])
        run([*shared, ROOT / 'receiver/DeliveryCore.swift', ROOT / 'receiver/MacPlatform.swift', ROOT / 'receiver/ReceiverMain.swift', '-o', resources / 'MacAttachmentReceiver'])
        run([*shared, ROOT / 'receiver/PairingWindow.swift', '-o', resources / 'ReceiverPairing'])
        iconset = staging / 'CodexDrop.iconset'; iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
                run(['/usr/bin/sips', '-z', size * scale, size * scale, icon, '--out', iconset / filename], stdout=subprocess.DEVNULL)
        run(['/usr/bin/iconutil', '-c', 'icns', iconset, '-o', resources / 'CodexDrop.icns'])
        info = plistlib.loads((ROOT / 'macos/Info.plist').read_bytes())
        info['CodexDropProjectRoot'] = str(ROOT)
        info['CodexDropPythonExecutable'] = str(Path(sys.executable).resolve())
        info['CodexDropIconSHA256'] = hashlib.sha256(icon.read_bytes()).hexdigest()
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        inputs = ['macos/ReceiverController.swift', 'macos/AppPresentation.swift', 'macos/CodexDropApp.swift', 'macos/Info.plist',
                  'receiver/DeliveryCore.swift', 'receiver/MacPlatform.swift', 'receiver/ReceiverMain.swift',
                  'receiver/PairingWindow.swift', 'receiver/mac_receiver.py', 'receiver/lan_receiver.py',
                  'assets/CodexDrop-icon.png', 'scripts/build-mac-app.py']
        manifest = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in inputs}
        (resources / 'BuildManifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for executable in (resources / 'MacAttachmentReceiver', resources / 'ReceiverPairing', executables / 'CodexDrop'):
            run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', executable])
            verify_team(executable)
        run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
        verify_team(app)
        destination = ROOT / app.name
        # Preserve prior bundles and all runtime evidence. Never replace private data.
        if destination.exists():
            archive = ROOT / '.codex-artifacts/builds' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            archive.mkdir(parents=True)
            shutil.move(destination, archive / destination.name)
        shutil.move(app, destination)
    print(f'Built and verified {destination}; Team {TEAM}. App was not opened.')

if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Mac app build failed: {error}', file=sys.stderr)
        raise SystemExit(1)
