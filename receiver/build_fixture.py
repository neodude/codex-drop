#!/usr/bin/env python3
"""Build/configure the isolated fixture; does not launch or control any app."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parent.parent
app = root / "ReceiverFixture.app"
(app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
metadata = {"CFBundleIdentifier": "com.example.CodexScreenshotReceiverFixture",
            "CFBundleExecutable": "ReceiverFixture", "CFBundleName": "Receiver Fixture",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "2", "NSPrincipalClass": "FixtureApplication",
            "NSHighResolutionCapable": True}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                str(Path(tempfile.gettempdir()) / "codex-attachment-probe-module-cache"),
                str(root / "receiver/FixtureHost.swift"), "-o", str(app / "Contents/MacOS/ReceiverFixture")], check=True)
if "com.apple.FinderInfo" in subprocess.check_output(["xattr", str(app)], text=True).splitlines():
    subprocess.run(["xattr", "-d", "com.apple.FinderInfo", str(app)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
(root / ".codex-artifacts").mkdir(mode=0o700, exist_ok=True)
(root / ".codex-artifacts/fixture-config.json").write_text(json.dumps({
    "pasteboard": "com.example.CodexScreenshotReceiver.Test." + str(uuid.uuid4()),
    "report": str(root / ".codex-artifacts/fixture-initial.json"), "mode": "standard", "runID": str(uuid.uuid4())}))
