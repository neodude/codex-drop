#!/usr/bin/env python3
"""Emulator-only fixture checks. Never use the real Mac receiver or a phone."""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', default='emulator-5580')
parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
args = parser.parse_args()
if not re.fullmatch(r'emulator-[0-9]+', args.serial):
    sys.exit('Refusing a physical device: use an emulator serial.')

def adb(*command, **kwargs):
    return subprocess.run([args.adb, '-s', args.serial, *command], check=True, **kwargs)

if adb('shell', 'getprop', 'ro.kernel.qemu', capture_output=True, text=True).stdout.strip() != '1':
    sys.exit('Refusing a device that is not an emulator.')
logs = root / '.codex-artifacts/android-checks'
logs.mkdir(parents=True, exist_ok=True)
for apk, extra in [('app-debug.apk', []), ('app-debug-androidTest.apk', ['-t'])]:
    folder = 'androidTest/debug' if extra else 'debug'
    with (logs / ('install-' + apk + '.log')).open('w') as output:
        adb('install', '-r', *extra, str(root / 'android/app/build/outputs/apk' / folder / apk), stdout=output, stderr=subprocess.STDOUT)

font = adb('shell', 'settings', 'get', 'system', 'font_scale', capture_output=True, text=True).stdout.strip()
with (logs / 'fixture-stderr.log').open('w') as errors:
    fixture = subprocess.Popen([sys.executable, str(root / 'android/core/src/test/resources/receiver_fixture.py'), str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True, env={**os.environ, 'CODEX_DROP_FIXTURE_DELAY': '2'})
    try:
        config = fixture.stdout.readline().strip()
        if not config:
            raise RuntimeError('Fixture failed to start. See fixture-stderr.log.')
        adb('shell', 'settings', 'put', 'system', 'font_scale', '1.5', capture_output=True)
        # Only ephemeral, disposable fixture credentials; never print the argument.
        with (logs / 'platform-flow-tests.log').open('w') as output:
            adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'fixture', "'" + config + "'", 'guide.guidelabs.codexdrop.test/androidx.test.runner.AndroidJUnitRunner', stdout=output, stderr=subprocess.STDOUT)
        result = (logs / 'platform-flow-tests.log').read_text()
        match = re.search(r'OK \((\d+) tests\)', result)
        if not match or int(match[1]) != 6 or 'FAILURES' in result:
            raise RuntimeError('Instrumented checks failed. See platform-flow-tests.log.')
        for name in ['setup.png', 'share-review.png', 'share-progress.png']:
            adb('pull', '/sdcard/Android/data/guide.guidelabs.codexdrop/files/' + name, str(logs / name), capture_output=True)
        print('PASS: 6 emulator checks, including 3-image pinned HTTPS round trip. Screenshots saved.')
    finally:
        adb('shell', 'settings', 'put', 'system', 'font_scale', font if font and font != 'null' else '1.0', capture_output=True)
        if fixture.poll() is None:
            fixture.stdin.write('stop\n'); fixture.stdin.flush(); fixture.stdin.close()
            try: fixture.wait(timeout=10)
            except subprocess.TimeoutExpired: fixture.kill(); fixture.wait()
