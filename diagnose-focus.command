#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
zsh "$RECEIVER_ROOT/receiver/build.zsh"
RECEIVER_STATUS=0
"$RECEIVER_ROOT/MacAttachmentReceiver" --diagnose-focus || RECEIVER_STATUS=$?
if [[ -t 0 ]]; then
  printf '\nPress any key to close…'
  read -k 1
  printf '\n'
fi
exit "$RECEIVER_STATUS"
