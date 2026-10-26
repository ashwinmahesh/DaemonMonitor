# Working on Daemon Monitor

Read README.md. Keep the five-row popover compact; startup configuration belongs behind each chevron. Native SwiftUI/AppKit lives in Sources/DaemonMonitor.swift; the Python standard-library lifecycle adapter is Resources/control.py. Prefer argument arrays, never shell interpolation/evaluation.

The user manages model startup manually. Preserve pre-existing services and active jobs. Never clear queues, submit inference jobs, download models, change model environments, or stop services from other checkouts/test ports to validate the monitor. After testing, stop only generators/queues started for that test. Busy generators must refuse stop; never force-kill them. ai-bridge clean shutdown can interrupt provider work, so use fixtures to test it and leave the user's running bridge alone.

Saved configuration applies at the next start; retain actual running endpoints. Synchronize the shared queue port and project folder within each image/voice family. Keep private settings, process records, credentials and logs in Application Support, outside the source tree.

Validate lifecycle changes with `python3 -m unittest discover -s Tests -v`, then build with `./build.sh`. Visually inspect the popover/settings when the Mac is available. `./install.sh` deploys to ~/Applications and installs the monitor's own login agent; it must not restart monitored daemons. Record actual verification and limitations in verification.json. Do not claim UI checks or real inference were performed unless they were.
