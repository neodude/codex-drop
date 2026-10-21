#!/bin/zsh
set -eu
DROP_ROOT=${0:A:h}
cd "$DROP_ROOT"
exec python3 scripts/build-mac-app.py
