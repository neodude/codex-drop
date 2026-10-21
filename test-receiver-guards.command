#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
zsh "$RECEIVER_ROOT/receiver/build.zsh"
print 'Guard 1: select some text in the target Codex draft during the countdown. Expected: blocked, no thumbnail.'
python3 "$RECEIVER_ROOT/receiver/live_test.py" --case blocked
print '\nGuard 2: use two existing Codex threads with EMPTY composers.'
print 'After pressing a key, focus the first composer during the 8-second countdown.'
print 'At the sound cue, switch to the second thread AND click its composer within 10 seconds.'
print 'Expected: blocked, no thumbnail in either thread; no sent message.'
printf '\nPress any key when ready…'
read -k 1
printf '\n'
RECEIVER_STATUS=0
python3 "$RECEIVER_ROOT/receiver/live_test.py" --case before-paste-race || RECEIVER_STATUS=$?
printf '\nPress any key to close…'
read -k 1
printf '\n'
exit "$RECEIVER_STATUS"
