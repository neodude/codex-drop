#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h}
cd "$RECEIVER_ROOT"
zsh "$RECEIVER_ROOT/receiver/build.zsh"

print 'Automatic delivery remains paused. These are three explicit one-shot tests.'
print 'Use a disposable thread with a short draft, e.g. receiver clipboard check.'
print 'Copy fresh plain text before starting. Nothing should be sent.'
print ''
print '1/3: EXISTING ATTACHMENT'
print 'Drag receiver-test-note.txt (beside this launcher) into the composer.'
print 'Keep your short draft. Press Return here, then focus that composer during the countdown.'
read -r
python3 "$RECEIVER_ROOT/receiver/live_test.py" --case standard
print 'Check: one NEW blue image, original file still attached, draft unchanged, nothing sent.'
print 'Remove ONLY the new blue image. Keep the original file and draft for the next checks.'
print ''
print '2/3: CLIPBOARD CHANGE BEFORE PASTE'
print 'Press Return here, then focus the SAME composer during the countdown.'
print 'At the BEEP, press Command-A, Command-C, then Right Arrow in the composer.'
print 'This copies the draft and clears the selection. You have 10 seconds; stay there.'
print 'Expected: BLOCKED, no new image, original file/draft preserved.'
read -r
python3 "$RECEIVER_ROOT/receiver/live_test.py" --case before-paste-race
print 'To check clipboard preservation: paste into a NEW TextEdit document; expect your copied draft.'
print 'Do not paste into Codex. Remove any unexpected blue image before continuing.'
print ''
print '3/3: CLIPBOARD CHANGE AFTER PASTE'
print 'Press Return here, then focus the SAME Codex composer during the countdown.'
print 'At the BEEP (after Paste), press Command-A, Command-C, then Right Arrow.'
print 'You have 10 seconds; stay in the composer until it finishes.'
print 'Expected: UNCERTAIN because the clipboard changed; exactly one new blue image, no retry.'
read -r
python3 "$RECEIVER_ROOT/receiver/live_test.py" --case after-paste-race
print 'Check: original file/draft preserved, exactly one blue image, nothing sent.'
print 'Check the copied draft in a NEW TextEdit document again; do not paste into Codex.'
print 'Remove the blue image and the test note before replying in this chat.'
printf '\nPress any key to close…'
read -k 1
printf '\n'
