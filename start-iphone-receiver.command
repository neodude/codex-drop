#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
zsh receiver/build.zsh
/usr/bin/xcrun swiftc -parse-as-library -module-cache-path "${TMPDIR:-/private/tmp}/codex-attachment-probe-module-cache" receiver/PairingWindow.swift -o ReceiverPairing
exec python3 receiver/lan_receiver.py --show-pairing "$@"
