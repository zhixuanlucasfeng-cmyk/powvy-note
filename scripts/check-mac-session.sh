#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --product SyncCheck
BIN=$(swift build --show-bin-path)
mkdir -p .deploy
swiftc -parse-as-library -I "$BIN/Modules" Sources/PowvyNote/CloudSync.swift tests/CloudSessionCheck.swift "$BIN/PowvyNoteCore.build/Core.swift.o" "$BIN/PowvyNoteCore.build/Sync.swift.o" -o .deploy/check-mac-session
.deploy/check-mac-session
