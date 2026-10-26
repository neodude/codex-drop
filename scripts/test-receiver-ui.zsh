#!/bin/zsh
set -eu
RECEIVER_ROOT=${0:A:h:h}
cd "$RECEIVER_ROOT"
if /usr/bin/pgrep -x ReceiverFixture >/dev/null; then
  print -u2 'Quit Receiver Fixture before rebuilding it, then rerun this test launcher.'
  exit 1
fi
zsh "$RECEIVER_ROOT/receiver/build.zsh"
python3 "$RECEIVER_ROOT/receiver/build_fixture.py"
/usr/bin/open "$RECEIVER_ROOT/ReceiverFixture.app" --args --exit-after 90
python3 "$RECEIVER_ROOT/receiver/fixture_matrix.py" "$@"
