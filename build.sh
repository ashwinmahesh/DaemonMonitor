#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
app_dir="$project_dir/build/Daemon Monitor.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI \
  "$project_dir/Sources/DaemonMonitor.swift" -o "$app_dir/Contents/MacOS/DaemonMonitor"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/control.py" "$app_dir/Contents/Resources/control.py"
xcrun swiftc "$project_dir/Tools/MakeIcon.swift" -o "$project_dir/build/MakeIcon"
"$project_dir/build/MakeIcon" "$project_dir/build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$project_dir/build/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir"
print -r -- "$app_dir"
