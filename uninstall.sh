#!/bin/zsh
set -euo pipefail
/opt/homebrew/bin/python3 - <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
label = 'local.daemonmonitor.app'
subprocess.run(['/bin/launchctl', 'bootout', 'gui/' + str(os.getuid()) + '/' + label], capture_output=True)
expected = str(Path.home() / 'Applications/Daemon Monitor.app/Contents/MacOS/DaemonMonitor')
for line in subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout.splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) == 2 and parts[1] == expected:
        try: os.kill(int(parts[0]), signal.SIGTERM)
        except ProcessLookupError: pass
(Path.home() / ('Library/LaunchAgents/' + label + '.plist')).unlink(missing_ok=True)
app = Path.home() / 'Applications/Daemon Monitor.app'
if app.exists(): shutil.rmtree(app)
print('Daemon Monitor removed. Service processes, data, and saved monitor settings were retained.')
PY
