#!/bin/zsh -f
set -eu
cd "${0:A:h}"
mkdir -p build 'Chipspace.app/Contents/MacOS' 'Chipspace.app/Contents/Resources/Web'
SDK=$(/usr/bin/xcrun --show-sdk-path)
for arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos12.0" -sdk "$SDK" -module-cache-path "$PWD/build/ModuleCache" Source/Chipspace.swift -o "build/chipspace-$arch" -framework AppKit -framework Network
done
/usr/bin/lipo -create build/chipspace-arm64 build/chipspace-x86_64 -output Chipspace.app/Contents/MacOS/Chipspace
/bin/cp Source/engine.command Chipspace.app/Contents/Resources/engine.command
/bin/cp Source/AppIcon.icns Chipspace.app/Contents/Resources/AppIcon.icns
/bin/cp Web/* Chipspace.app/Contents/Resources/Web/
/bin/cat > Chipspace.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Chipspace</string><key>CFBundleIdentifier</key><string>local.chipspace.storage</string><key>CFBundleName</key><string>Chipspace</string><key>CFBundleDisplayName</key><string>Chipspace</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>12.0</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
/usr/bin/codesign --force --sign - Chipspace.app
/usr/bin/lipo -info Chipspace.app/Contents/MacOS/Chipspace
print 'Built Chipspace.app for Apple silicon and Intel Macs (macOS 12+).'
