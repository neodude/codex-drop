#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
mkdir -p .codex-artifacts/checks
python3 -m unittest discover -s receiver -p test_lan_receiver.py
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "${TMPDIR:-/private/tmp}/codex-attachment-probe-module-cache" iphone/Shared/Pairing.swift iphone/Shared/ReceiverClient.swift iphone/Shared/ImageEncoder.swift iphone/Checks/ClientChecks.swift -o .codex-artifacts/checks/iphone-client-checks
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "${TMPDIR:-/private/tmp}/codex-attachment-probe-module-cache" iphone/Shared/Pairing.swift iphone/Shared/ReceiverClient.swift iphone/Shared/ImageEncoder.swift iphone/Checks/BatchChecks.swift -o .codex-artifacts/checks/iphone-batch-checks
.codex-artifacts/checks/iphone-batch-checks
python3 receiver/transport_checks.py
