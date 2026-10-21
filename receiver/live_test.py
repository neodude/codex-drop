#!/usr/bin/env python3
"""USER-RUN ONLY: actual localhost receive -> queue -> native Codex attachment."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import threading
import time
import uuid

from mac_receiver import JobQueue, DeliveryWorker, make_server, native_delivery


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=("standard", "blocked", "before-paste-race", "after-paste-race"), default="standard")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    run_id = str(uuid.uuid4())
    directory = root / ".codex-artifacts" / "live-tests" / run_id
    queue = JobQueue(directory)
    token = secrets.token_urlsafe(32)
    server = make_server(queue, token)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    key = str(uuid.uuid4())
    image = (root / "test-image.png").read_bytes()
    def request(method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
        auth = {"Authorization": "Bearer " + token}; auth.update(headers or {})
        try:
            connection.request(method, path, body, auth)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()
    try:
        headers = {"Content-Type": "image/png", "X-Request-ID": key}
        status, first = request("POST", "/v1/screenshots", image, headers)
        duplicate_status, duplicate = request("POST", "/v1/screenshots", image, headers)
        if status != 202 or duplicate_status != 202 or first["job"]["id"] != duplicate["job"]["id"] or len(queue.list()) != 1:
            raise RuntimeError("HTTP receipt/idempotency check failed before any UI action")
        print("HTTP receive and duplicate-request checks passed. Exactly one job is queued.", flush=True)
        if args.case == "blocked":
            print("NEGATIVE TEST: leave a DIFFERENT app frontmost, or select text in the Codex composer.", flush=True)
        else:
            print("Switch to the desired Codex thread and click its MAIN composer; leave no text selected.", flush=True)
        if args.case == "before-paste-race":
            print("At the sound cue / TEST WINDOW message, switch threads/windows or copy something during the 10-second hold. Expected: blocked, no paste.", flush=True)
        if args.case == "after-paste-race":
            print("At the sound cue / TEST WINDOW AFTER Paste, copy something during the 10-second hold. Expected: uncertain, no retry.", flush=True)
        for remaining in range(8, 0, -1):
            print(str(remaining) + "…", flush=True); time.sleep(1)
        extra = ("--live-test-repair", "eager-png-v2")
        if args.case == "before-paste-race": extra += ("--test-stage-hold", "10")
        if args.case == "after-paste-race": extra += ("--test-after-paste-hold", "10")
        worker = DeliveryWorker(queue, lambda job: native_delivery(job, test_arguments=extra, live_output=True))
        worker.once()
        _, job = request("GET", "/v1/jobs/" + key)
        expected = "verified" if args.case == "standard" else "blocked" if args.case in ("blocked", "before-paste-race") else "uncertain"
        called_again = worker.once()
        report = {
            "case": args.case, "expectedState": expected, "actualState": job["state"],
            "stateMatchesExpected": job["state"] == expected,
            "duplicateHTTPRequests": 2, "durableJobs": len(queue.list()),
            "secondWorkerCallDidWork": called_again,
            "imageSHA256": hashlib.sha256(image).hexdigest(), "job": job,
            "visualCheck": "pending_user_confirmation",
            "limitations": ["No stable thread ID", "Draft check covers text only", "Verify visible thumbnail, existing attachments and absence of a sent message manually"]
        }
        (directory / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
        print("Report: " + str(directory / "report.json"))
        print("Check Codex visually. No Send action is present in this helper; remove the test thumbnail manually when finished.")
        return 0 if report["stateMatchesExpected"] and not called_again else 1
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
