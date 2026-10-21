#!/bin/zsh
set -eu
TASK_DIR=${0:A:h}
cd "$TASK_DIR"
if [[ ! -x "$TASK_DIR/AttachmentProbe" || "$TASK_DIR/AttachmentProbe.swift" -nt "$TASK_DIR/AttachmentProbe" ]]; then
  /usr/bin/xcrun swiftc -module-cache-path "${TMPDIR:-/private/tmp}/codex-attachment-probe-module-cache" "$TASK_DIR/AttachmentProbe.swift" -o "$TASK_DIR/AttachmentProbe"
fi
PROBE_STATUS=0
"$TASK_DIR/AttachmentProbe" "$@" || PROBE_STATUS=$?
if [[ -t 0 ]]; then
  printf '\nPress any key to close…'
  read -k 1
  printf '\n'
fi
exit "$PROBE_STATUS"
