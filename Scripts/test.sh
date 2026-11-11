#!/usr/bin/env bash
# Runs the tests. With full Xcode, plain `swift test` works. With only the Command Line Tools, Swift Testing needs
# its framework folder spelled out, and the CLT's _Testing_Foundation overlay ships without its module, so
# cross-import overlays are switched off.
#   Scripts/test.sh [extra swift test arguments, e.g. --filter Rejecting]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
