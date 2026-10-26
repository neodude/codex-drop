#!/usr/bin/env python3
"""Build/sign the local Codex Drop app; never starts it or the receiver."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
from build_config import (MACOS_MINIMUM, add_config_arguments, resolve_config,
                          select_signing_identity, ensure_destination_stopped, verify_macos_minimum)

def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)

def signing_identity(config):
    identities = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout
    valid = {fingerprint.upper(): name for fingerprint, name in re.findall(r'([0-9A-Fa-f]{40})\s+"([^"\n]+)"', identities)}
    certificates = run(['/usr/bin/security', 'find-certificate', '-a', '-c', 'Apple Development', '-p'], capture_output=True, text=True).stdout
    candidates = []
    for certificate in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S):
        details = run(['/usr/bin/openssl', 'x509', '-noout', '-subject', '-fingerprint', '-sha1'], input=certificate, capture_output=True, text=True).stdout
        team = re.search(r'\bOU\s*=\s*([A-Z0-9]{10})\b', details)
        fingerprint = details.split('Fingerprint=')[-1].strip().replace(':', '').upper()
        if team and fingerprint in valid:
            candidates.append((fingerprint, valid[fingerprint], team[1]))
    return select_signing_identity(candidates, config.apple_team_id, config.mac_signing_identity)


def verify_team(path, team):
    details = run(['/usr/bin/codesign', '-d', '--verbose=4', path], capture_output=True, text=True).stderr
    if f'TeamIdentifier={team}' not in details.splitlines():
        raise RuntimeError(f'Incorrect signing team: {path.name}')
    run(['/usr/bin/codesign', '--verify', '--strict', path])


def guard_destination(destination):
    processes = run(['/bin/ps', '-axww', '-o', 'pid=,comm=,command='], capture_output=True, text=True).stdout
    ensure_destination_stopped(destination, processes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-root',type=Path,default=ROOT,help='Existing project whose private receiver data this build uses')
    parser.add_argument('--output',type=Path,default=ROOT/'Codex Drop.app',help='Destination .app bundle (prior bundle is archived)')
    add_config_arguments(parser)
    args = parser.parse_args()
    config = resolve_config(args)
    runtime_root = args.runtime_root.resolve()
    destination = args.output.resolve()
    if not (runtime_root/'receiver/mac_receiver.py').is_file() or destination.suffix != '.app' or not destination.parent.is_dir():
        raise RuntimeError('Invalid runtime project or app destination')
    icon = ROOT / 'assets/CodexDrop-icon.png'
    if not icon.is_file():
        raise RuntimeError('Missing assets/CodexDrop-icon.png')
    guard_destination(destination)
    identity = signing_identity(config)
    with tempfile.TemporaryDirectory(prefix='CodexDrop-build-') as temporary:
        staging = Path(temporary)
        app = staging / 'Codex Drop.app'
        contents = app / 'Contents'
        resources = contents / 'Resources'
        executables = contents / 'MacOS'
        resources.mkdir(parents=True); executables.mkdir()
        (resources / 'receiver').mkdir()
        for name in ('mac_receiver.py', 'lan_receiver.py', 'runtime_storage.py', 'video_container.py'):
            shutil.copy2(ROOT / 'receiver' / name, resources / 'receiver' / name)
        shutil.copy2(ROOT / 'iphone/Share/Assets.xcassets/DropMark.imageset/DropMark.png', resources / 'DropMark.png')
        cache = staging / 'swift-cache'
        shared = ['/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', cache,
                  '-target', f'{platform.machine()}-apple-macosx{MACOS_MINIMUM}']
        run([*shared, ROOT / 'macos/ReceiverController.swift', ROOT / 'macos/AppPresentation.swift', ROOT / 'macos/StatusWindowView.swift', ROOT / 'macos/CodexDropApp.swift', '-o', executables / 'CodexDrop'])
        run([*shared, ROOT / 'receiver/DeliveryCore.swift', ROOT / 'receiver/MacPlatform.swift', ROOT / 'receiver/ReceiverMain.swift', '-o', resources / 'MacAttachmentReceiver'])
        run([*shared, ROOT / 'receiver/PairingWindow.swift', '-o', resources / 'ReceiverPairing'])
        iconset = staging / 'CodexDrop.iconset'; iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
                run(['/usr/bin/sips', '-z', size * scale, size * scale, icon, '--out', iconset / filename], stdout=subprocess.DEVNULL)
        run(['/usr/bin/iconutil', '-c', 'icns', iconset, '-o', resources / 'CodexDrop.icns'])
        info = plistlib.loads((ROOT / 'macos/Info.plist').read_bytes())
        info['CFBundleIdentifier'] = config.mac_bundle_id
        info['LSMinimumSystemVersion'] = MACOS_MINIMUM
        info['CodexDropProjectRoot'] = str(runtime_root)
        info['CodexDropPythonExecutable'] = str(Path(sys.executable).resolve())
        info['CodexDropIconSHA256'] = hashlib.sha256(icon.read_bytes()).hexdigest()
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        inputs = ['macos/ReceiverController.swift', 'macos/AppPresentation.swift', 'macos/CodexDropApp.swift', 'macos/StatusWindowView.swift', 'macos/Info.plist',
                  'receiver/DeliveryCore.swift', 'receiver/MacPlatform.swift', 'receiver/ReceiverMain.swift',
                  'receiver/PairingWindow.swift', 'receiver/mac_receiver.py', 'receiver/lan_receiver.py', 'receiver/runtime_storage.py', 'receiver/video_container.py',
                  'assets/CodexDrop-icon.png', 'iphone/Share/Assets.xcassets/DropMark.imageset/DropMark.png', 'scripts/build-mac-app.py', 'scripts/build_config.py']
        manifest = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in inputs}
        (resources / 'BuildManifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for executable in (resources / 'MacAttachmentReceiver', resources / 'ReceiverPairing', executables / 'CodexDrop'):
            run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', executable])
            verify_team(executable, config.apple_team_id)
            commands = run(['/usr/bin/otool', '-l', executable], capture_output=True, text=True).stdout
            verify_macos_minimum(commands)
        run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
        verify_team(app, config.apple_team_id)
        # Preserve prior bundles and all runtime evidence. Never replace private data.
        guard_destination(destination)
        if destination.exists():
            archive = ROOT / '.codex-artifacts/builds' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            archive.mkdir(parents=True)
            shutil.move(destination, archive / destination.name)
        shutil.move(app, destination)
    print(f'Built and verified {destination}; Team {config.apple_team_id}. App was not opened.')

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Mac app build failed: {error}', file=sys.stderr)
        raise SystemExit(1)
