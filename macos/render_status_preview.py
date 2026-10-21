#!/usr/bin/env python3
"""Render the real status view with fake state in a separate, offscreen accessory app.

No receiver/controller, canonical data, network, clipboard, settings writes, or
application activation. Every preview action is inert. PNGs capture NSViews only.
"""
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / '.codex-artifacts/design-consistency/mac'
output.mkdir(parents=True, exist_ok=True)
app = output / 'StatusPreview.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.codexdrop.design-preview', 'CFBundleExecutable': 'StatusPreview',
    'CFBundleName': 'Codex Drop Design Preview', 'LSUIElement': True,
}))
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(output / 'swift-cache'),
    str(ROOT / 'macos/StatusWindowView.swift'), str(ROOT / 'macos/StatusWindowPreview.swift'),
    '-o', str(macos / 'StatusPreview')], check=True)
subprocess.run([str(macos / 'StatusPreview'), str(output),
    str(ROOT / 'iphone/Share/Assets.xcassets/DropMark.imageset/DropMark.png')], check=True)
