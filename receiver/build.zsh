#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h:h}
RECEIVER_BINARY="$RECEIVER_ROOT/MacAttachmentReceiver"
RECEIVER_REBUILD=0
[[ -x "$RECEIVER_BINARY" ]] || RECEIVER_REBUILD=1
for RECEIVER_SOURCE in "$RECEIVER_ROOT/receiver/DeliveryCore.swift" "$RECEIVER_ROOT/receiver/MacPlatform.swift" "$RECEIVER_ROOT/receiver/ReceiverMain.swift"; do
  [[ "$RECEIVER_SOURCE" -nt "$RECEIVER_BINARY" ]] && RECEIVER_REBUILD=1
done
if (( RECEIVER_REBUILD )); then
  /usr/bin/xcrun swiftc -module-cache-path "${TMPDIR:-/private/tmp}/codex-attachment-probe-module-cache" \
    "$RECEIVER_ROOT/receiver/DeliveryCore.swift" "$RECEIVER_ROOT/receiver/MacPlatform.swift" \
    "$RECEIVER_ROOT/receiver/ReceiverMain.swift" -o "$RECEIVER_BINARY"
fi
