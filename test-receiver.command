#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
if [[ -f "$RECEIVER_ROOT/.receiver-paused" ]]; then
  print 'Automatic delivery remains paused. This runs ONE explicit repaired eager-PNG test.'
fi
zsh "$RECEIVER_ROOT/receiver/build.zsh"
RECEIVER_STATUS=0
python3 "$RECEIVER_ROOT/receiver/live_test.py" "$@" || RECEIVER_STATUS=$?
if [[ -t 0 ]]; then
  printf '\nPress any key to close…'
  read -k 1
  printf '\n'
fi
exit "$RECEIVER_STATUS"
