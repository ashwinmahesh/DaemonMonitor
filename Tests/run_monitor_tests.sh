#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
mkdir -p "$project_dir/build"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts "$project_dir/Sources/DaemonMonitor.swift" "$project_dir/Sources/Performance.swift" \
  "$project_dir/Tests/MonitorTests.swift" -o "$project_dir/build/MonitorTests"
"$project_dir/build/MonitorTests"
