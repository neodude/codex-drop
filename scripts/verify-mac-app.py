#!/usr/bin/env python3
"""Verify the local bundle without opening the application or receiver."""
import argparse
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import sys
from build_config import ROOT, MACOS_MINIMUM, add_config_arguments, resolve_config, verify_macos_minimum


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "Codex Drop.app")
    parser.add_argument("--runtime-root", type=Path, default=ROOT)
    add_config_arguments(parser)
    args = parser.parse_args()
    config = resolve_config(args)
    app = args.app.resolve()
    resources = app / 'Contents/Resources'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == config.mac_bundle_id, 'Incorrect Mac bundle identifier')
    require(info['CodexDropProjectRoot'] == str(args.runtime_root.resolve()), 'Incorrect runtime project')
    require(info['LSUIElement'] is True, 'Missing menu bar app setting')
    require(info['LSMinimumSystemVersion'] == MACOS_MINIMUM, 'Incorrect advertised macOS minimum')
    require(info['NSBonjourServices'] == ['_codexshot._tcp'], 'Incorrect Bonjour service')
    require(info['CodexDropIconSHA256'] == hashlib.sha256((ROOT / 'assets/CodexDrop-icon.png').read_bytes()).hexdigest(), 'Stale icon')
    require(Path(info['CodexDropPythonExecutable']).is_file(), 'Rebuild with an installed Python runtime')
    for private in ('receiver-data', 'pairing-code.txt', '*.log'):
        require(not list(app.rglob(private)), f'Private runtime file in bundle: {private}')
    for name in ('MacAttachmentReceiver', 'ReceiverPairing', 'CodexDrop.icns', 'receiver/mac_receiver.py', 'receiver/lan_receiver.py', 'receiver/runtime_storage.py', 'receiver/video_container.py'):
        require((resources / name).is_file(), f'Missing resource {name}')
    for name, digest in json.loads((resources / 'BuildManifest.json').read_text()).items():
        require(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest, f'Rebuild required after source change: {name}')
    binaries = (resources / 'MacAttachmentReceiver', resources / 'ReceiverPairing', app / 'Contents/MacOS/CodexDrop')
    for executable in (app, *binaries):
        result = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(executable)], capture_output=True, text=True, check=True)
        require(f'TeamIdentifier={config.apple_team_id}' in result.stderr.splitlines(), f'Unexpected team for {executable.name}')
    for executable in binaries:
        result = subprocess.run(['/usr/bin/otool', '-l', str(executable)], capture_output=True, text=True, check=True)
        verify_macos_minimum(result.stdout)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'Bundle inspection passed: source hashes, runtime paths, resources, Team {config.apple_team_id}, and macOS {MACOS_MINIMUM} in all three Mach-O binaries.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Mac app verification failed: {error}', file=sys.stderr)
        raise SystemExit(1)
