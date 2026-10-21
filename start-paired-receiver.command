#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
print 'Starting the paired receiver. No QR scan needed; leave this Terminal running.'
print 'Click the intended Codex message box so its text caret is blinking before sharing.'
zsh receiver/build.zsh
exec python3 receiver/lan_receiver.py "$@"
