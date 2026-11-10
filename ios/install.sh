#!/bin/sh
# Build, sign (free personal team) and install Powvy Note on the connected iPad, then launch it.
# Personal-team apps stop opening after 7 days: run this again to renew. Notes on the iPad are kept.
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/powvy-note-ios"
xcodebuild -project PowvyNote.xcodeproj -target PowvyNoteiPad -configuration Debug -sdk iphoneos \
  SYMROOT="$OUT" -allowProvisioningUpdates build | grep -E "error|BUILD (SUCCEEDED|FAILED)"
DEVICE=$(xcrun devicectl list devices | grep connected | grep iPad | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
[ -n "$DEVICE" ] || { echo "没找到已连接的 iPad：用数据线连上并解锁"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$OUT/Debug-iphoneos/Powvy Note.app" >/dev/null
xcrun devicectl device process launch --device "$DEVICE" com.zhixuanlucasfeng.powvynote >/dev/null
echo "已装到 iPad 并打开。7 天后再运行一次这个脚本续期。"
