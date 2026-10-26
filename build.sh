#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
app_dir="$project_dir/build/Daemon Monitor.app"
build_progress_pid=""

cleanup_progress() {
  if [[ -n "$build_progress_pid" ]]; then
    kill "$build_progress_pid" 2>/dev/null || true
    wait "$build_progress_pid" 2>/dev/null || true
    build_progress_pid=""
  fi
}
trap cleanup_progress EXIT

run_step() {
  local description="$1"
  shift
  local started_at=$SECONDS
  local step_result=0
  print -r -- "  -> $description"
  (
    local timer_pid=""
    trap 'if [[ -n "$timer_pid" ]]; then kill "$timer_pid" 2>/dev/null || true; wait "$timer_pid" 2>/dev/null || true; fi; exit 0' TERM
    while true; do
      sleep 5 &
      timer_pid=$!
      wait "$timer_pid" || exit 0
      timer_pid=""
      print -r -- "     Still working: $description ($((SECONDS - started_at))s elapsed)"
    done
  ) &
  build_progress_pid=$!
  "$@" || step_result=$?
  cleanup_progress
  if (( step_result != 0 )); then
    print -u2 -r -- "     Failed: $description (exit $step_result)"
    return "$step_result"
  fi
  print -r -- "     Done ($((SECONDS - started_at))s)"
}

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
run_step "Compile the menu bar app" xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI \
  "$project_dir/Sources/DaemonMonitor.swift" -o "$app_dir/Contents/MacOS/DaemonMonitor"
run_step "Copy app metadata" cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
run_step "Copy the service helper" cp "$project_dir/Resources/control.py" "$app_dir/Contents/Resources/control.py"
run_step "Compile the icon generator" xcrun swiftc "$project_dir/Tools/MakeIcon.swift" -o "$project_dir/build/MakeIcon"
run_step "Render the app icon" "$project_dir/build/MakeIcon" "$project_dir/build/AppIcon.iconset"
run_step "Package the app icon" /usr/bin/iconutil -c icns "$project_dir/build/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
run_step "Sign the app" codesign --force --sign - "$app_dir"
print -r -- "Build complete: $app_dir"
