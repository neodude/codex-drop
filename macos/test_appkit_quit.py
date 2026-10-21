#!/usr/bin/env python3
"""Bounded real-AppKit Quit regression using only a temporary fake child process.

Run with normal user GUI-session access; sandboxed LaunchServices cannot initialize AppKit.
No product receiver, queue, clipboard, network, AppleScript, or other application's UI.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
ARTIFACT = ROOT / '.codex-artifacts/checks/appkit-quit-fixture'
ARTIFACT.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='CodexDrop-quit-check-') as build:
    executable = Path(build) / 'QuitFixture'
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(build) / 'cache'),
                    str(ROOT / 'macos/AppKitQuitFixture.swift'), '-o', str(executable)], check=True)
    results = []
    for mode in ('default', 'common', 'modal', 'common-modal'):
        with tempfile.TemporaryDirectory(prefix='CodexDrop-quit-' + mode + '-') as temporary:
            started = time.monotonic()
            process = subprocess.Popen([str(executable), mode, temporary], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                output, error = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()  # Only this harness-owned fixture PID; fake child has already been asked to stop.
                output, error = process.communicate()
                error += b'\nHarness timeout\n'
            root = Path(temporary)
            events = (root / 'events.log').read_text() if (root / 'events.log').exists() else ''
            child = (root / 'child.log').read_text() if (root / 'child.log').exists() else ''
            result = {'mode': mode, 'exit': process.returncode, 'elapsed': round(time.monotonic() - started, 3),
                      'events': events, 'child': child, 'stderr': error.decode(errors='replace')}
            (ARTIFACT / (mode + '.json')).write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result), flush=True)
            results.append(result)
    assert all('delegate-terminate-later' in result['events'] for result in results), 'AppKit did not initialize; run with normal GUI-session access'
    assert all('cleaned-up' in result['child'] for result in results), 'fake child must finish graceful cleanup in every case'
    default = next(result for result in results if result['mode'] == 'default')
    fixed = next(result for result in results if result['mode'] == 'common-modal')
    assert default['exit'] == 124 and 'watchdog-timeout' in default['events'], 'old default-only timer did not reproduce the hang'
    assert fixed['exit'] == 0 and 'will-terminate' in fixed['events'], 'common + modal timer did not finish termination'
    print('AppKit Quit regression passed: default timer reproduces hang; common + modal timer exits after fake child cleanup.')
