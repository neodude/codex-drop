#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
print 'Prepare two existing Codex threads with EMPTY composers.'
print 'During the 8-second countdown, focus the FIRST thread and click its composer.'
print 'At the sound cue / TEST WINDOW message, switch to the SECOND thread and click its composer.'
print 'You have 10 seconds after the cue. Stay in the second composer until the test finishes.'
print 'Expected: BLOCKED, no new thumbnail in either thread, and no sent message.'
zsh "$RECEIVER_ROOT/receiver/build.zsh"
RECEIVER_STATUS=0
python3 "$RECEIVER_ROOT/receiver/live_test.py" --case before-paste-race || RECEIVER_STATUS=$?
printf '\nPress any key to close…'
read -k 1
printf '\n'
exit "$RECEIVER_STATUS"
