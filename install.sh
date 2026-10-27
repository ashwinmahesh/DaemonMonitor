#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
print -r -- "[1/5] Building Daemon Monitor..."
"$project_dir/build.sh"
/opt/homebrew/bin/python3 -u - "$project_dir" <<'PY'
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
source = Path(sys.argv[1]) / 'build/Daemon Monitor.app'
installed = Path.home() / 'Applications/Daemon Monitor.app'
label = 'local.daemonmonitor.app'
domain = 'gui/' + str(os.getuid())
agent = Path.home() / ('Library/LaunchAgents/' + label + '.plist')
support = Path.home() / 'Library/Application Support/DaemonMonitor'
(support / 'logs').mkdir(parents=True, exist_ok=True, mode=0o700)
# Stop only this app during replacement; monitored services keep running.
print('[2/5] Stopping the previous monitor, if running...')
subprocess.run(['/bin/launchctl', 'bootout', domain + '/' + label], capture_output=True)
print('[3/5] Installing the app...')
if installed.exists():
    expected = str(Path.home() / 'Applications/Daemon Monitor.app/Contents/MacOS/DaemonMonitor')
    for line in subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == expected:
            try: os.kill(int(parts[0]), signal.SIGTERM)
            except ProcessLookupError: pass
    backup = installed.with_suffix('.app.previous')
    if backup.exists(): shutil.rmtree(backup)
    print('  Keeping the previous app at: ' + str(backup))
    installed.rename(backup)
installed.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(source, installed)
print('[4/5] Configuring startup at login...')
agent.parent.mkdir(parents=True, exist_ok=True)
agent.write_bytes(plistlib.dumps({
    'Label': label,
    'ProgramArguments': [str(installed / 'Contents/MacOS/DaemonMonitor')],
    'RunAtLoad': True,
    'KeepAlive': {'SuccessfulExit': False},
    'ThrottleInterval': 10,
    'ProcessType': 'Interactive',
    'StandardOutPath': str(support / 'logs/app.log'),
    'StandardErrorPath': str(support / 'logs/app.log')
}))
agent.chmod(0o600)
print('[5/5] Launching Daemon Monitor...')
subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(agent)], check=True)
print('Installation complete.')
print('Installed and launched: ' + str(installed))
print('Login startup: ' + str(agent))
PY
