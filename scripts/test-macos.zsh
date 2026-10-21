#!/bin/zsh
set -eu
DROP_ROOT=${0:A:h:h}
DROP_TEST_ROOT=$(mktemp -d "${TMPDIR:-/private/tmp}/CodexDrop-tests.XXXXXX")
trap 'rm -rf "$DROP_TEST_ROOT"' EXIT
/usr/bin/xcrun swiftc -module-cache-path "$DROP_TEST_ROOT/cache" \
  "$DROP_ROOT/macos/ReceiverController.swift" "$DROP_ROOT/macos/LifecycleTests.swift" \
  "$DROP_ROOT/macos/LifecycleTestMain.swift" -o "$DROP_TEST_ROOT/LifecycleChecks"
"$DROP_TEST_ROOT/LifecycleChecks"
/usr/bin/plutil -lint "$DROP_ROOT/macos/Info.plist"
python3 "$DROP_ROOT/macos/test_appkit_quit.py"
