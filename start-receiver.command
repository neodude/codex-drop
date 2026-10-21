#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
if [[ -f "$RECEIVER_ROOT/.receiver-paused" ]]; then
  print -u2 'Receiver is paused. See .receiver-paused for details.'
  exit 1
fi
zsh "$RECEIVER_ROOT/receiver/build.zsh"
exec python3 "$RECEIVER_ROOT/receiver/mac_receiver.py" serve "$@"
