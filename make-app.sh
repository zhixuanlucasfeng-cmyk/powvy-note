#!/bin/sh
# Build "build/Powvy Note.app" (universal arm64+x86_64, ad-hoc signed) and build/PowvyNote.zip.
# Icon: Resources/AppIcon.icns (regenerate with: swift tools/make-icon.swift /tmp/x.iconset && iconutil -c icns ...)
set -e
cd "$(dirname "$0")"
for t in arm64 x86_64; do
  swift build -c release --product PowvyNote --triple $t-apple-macosx14.0
done
APP="build/Powvy Note.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/PowvyNote .build/x86_64-apple-macosx/release/PowvyNote \
  -output "$APP/Contents/MacOS/PowvyNote"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Powvy Note</string>
  <key>CFBundleDisplayName</key><string>Powvy Note</string>
  <key>CFBundleIdentifier</key><string>com.lucasfeng.powvynote</string>
  <key>CFBundleExecutable</key><string>PowvyNote</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.1</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
rm -f build/PowvyNote.zip
(cd build && cp ../安装说明.txt . && zip -qry PowvyNote.zip "Powvy Note.app" 安装说明.txt)
echo "$PWD/$APP"
