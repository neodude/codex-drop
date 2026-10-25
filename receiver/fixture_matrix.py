#!/usr/bin/env python3
"""Operate ONLY the isolated fixture app and a private pasteboard; never Codex."""
import json
import hashlib
from pathlib import Path
import subprocess
import time
import uuid


def main():
    root = Path(__file__).resolve().parent.parent
    config_path = root / ".codex-artifacts/fixture-config.json"
    config = json.loads(config_path.read_text())
    fixture_image = root / ".codex-artifacts/fixture-source.png"
    fixture_image.write_bytes((root / "test-image.png").read_bytes())
    results = []
    cases = [("two-window-standard", "verified"), ("two-window-activation", "verified"),
             ("window-before-paste", "blocked"), ("background-focus", "verified"), ("background-focus-change", "uncertain"),
             ("unfocused", "verified"), ("unfocused-selected", "blocked"), ("ambiguous", "blocked"),
             ("standard", "verified"), ("delayed", "verified"), ("no-ack", "uncertain"),
             ("clipboard-change", "uncertain"), ("window-change", "uncertain"),
             ("draft-change", "uncertain"), ("selected-text", "blocked"),
             ("batch-standard", "verified"), ("batch-uncertain", "uncertain"), ("batch-focus-change", "uncertain"),
             ("activation-required", "verified")]
    for mode, expected in cases:
        run_id = str(uuid.uuid4())
        fixture_report = root / f".codex-artifacts/fixture-{mode}.json"
        native_report = root / f".codex-artifacts/fixture-native-{mode}.json"
        config.update(mode=mode, runID=run_id, report=str(fixture_report))
        config_path.write_text(json.dumps(config))
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if fixture_report.exists() and json.loads(fixture_report.read_text()).get("runID") == run_id:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("Fixture did not reset; no native delivery attempted")
        batch = mode.startswith("batch-") or mode in ("background-focus-change", "activation-required")
        input_path = fixture_image
        if batch:
            manifest = root / ".codex-artifacts/fixture-batch.json"
            manifest.write_text(json.dumps({"images": [{"path": str(input_path), "sha256": hashlib.sha256(input_path.read_bytes()).hexdigest()}] * 3}))
            input_path = manifest
        arguments = [str(root / "MacAttachmentReceiver"), "--batch" if batch else "--image", str(input_path),
                     "--result", str(native_report), "--fixture-pasteboard", config["pasteboard"]]
        if mode in ("activation-required", "two-window-activation"): arguments += ["--fixture-activation", "required"]
        if mode == "window-before-paste": arguments += ["--test-stage-hold", "1"]
        process = subprocess.run(arguments,
                                 capture_output=True, text=True, timeout=15)
        if process.returncode:
            raise RuntimeError("Fixture-only native helper failed")
        native = json.loads(native_report.read_text())
        time.sleep(0.2)
        fixture = json.loads(fixture_report.read_text())
        expected_pastes = 0 if expected == "blocked" else 3 if mode in ("batch-standard", "activation-required") else 2 if mode == "batch-uncertain" else 1
        passed = native["status"] == expected and fixture["pasteCount"] == expected_pastes
        passed = passed and fixture["draftUnchanged"] == (mode != "draft-change")
        passed = passed and fixture["maxHeartbeatGapMS"] < 1500
        passed = passed and (fixture["clipboardIsNewer"] if mode == "clipboard-change" else fixture["clipboardIsOriginal"])
        expected_attachments = 0 if expected == "blocked" or mode in ("no-ack", "clipboard-change", "window-change") else 3 if mode in ("batch-standard", "activation-required") else 1
        passed = passed and fixture["attachments"] == expected_attachments
        if batch:
            passed = passed and native["totalCount"] == 3 and native["verifiedCount"] == (3 if mode in ("batch-standard", "activation-required") else 0 if mode in ("batch-focus-change", "background-focus-change") else 1)
            if mode == "batch-uncertain": passed = passed and native["items"][2]["status"] == "not_attempted"
            if mode in ("batch-focus-change", "background-focus-change"):
                passed = passed and native["items"][1]["status"] == "not_attempted" and not fixture["composerFocused"]
        if mode == "unfocused": passed = passed and fixture["composerFocused"]
        if mode == "activation-required": passed = passed and fixture["appActive"]
        if mode == "delayed": passed = passed and native["elapsedMS"] >= 3500
        if mode.startswith("two-window-"):
            passed = passed and fixture.get("windowCount") == 2 and fixture.get("otherDraftUnchanged") is True
        if mode == "two-window-activation": passed = passed and fixture["appActive"]
        if mode == "window-before-paste":
            passed = passed and native["pasteAttempted"] is False and fixture.get("windowCount") == 2
        item = {"case": mode, "passed": passed, "delivery": native, "fixture": fixture}
        results.append(item)
        print(json.dumps({"case": mode, "passed": passed, "status": native["status"],
                          "elapsedMS": native["elapsedMS"], "maxHeartbeatGapMS": fixture["maxHeartbeatGapMS"]}), flush=True)
        if not passed:
            break
    report = {"scope": "actual AX menu Paste in isolated AppKit fixture; private pasteboard only; fixture target can be background",
              "allPassed": len(results) == len(cases) and all(r["passed"] for r in results), "cases": results}
    (root / ".codex-artifacts/fixture-matrix.json").write_text(json.dumps(report, indent=2))
    return 0 if report["allPassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
