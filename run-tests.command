#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
mkdir -p "$RECEIVER_ROOT/.codex-artifacts/checks"
zsh "$RECEIVER_ROOT/receiver/build.zsh"
export CODEX_DROP_TEST_RECEIVER="$RECEIVER_ROOT/MacAttachmentReceiver"
/usr/bin/xcrun swiftc -module-cache-path "${TMPDIR:-/private/tmp}/codex-attachment-probe-module-cache" \
  "$RECEIVER_ROOT/receiver/DeliveryCore.swift" "$RECEIVER_ROOT/receiver/CoreTests.swift" \
  -o "$RECEIVER_ROOT/.codex-artifacts/checks/core-tests"
"$RECEIVER_ROOT/.codex-artifacts/checks/core-tests"
python3 -m unittest discover -s receiver -p 'test_*.py'
"$RECEIVER_ROOT/MacAttachmentReceiver" --self-test
