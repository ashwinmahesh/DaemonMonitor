# Daemon Monitor

A native macOS menu bar app for the local ai-bridge, ImageGen-Service and VoiceGen-Service. Click the activity icon in the right side of the menu bar to open its attached popover. The main view contains three rows: AI Bridge with one switch, Image Generator with Service and Queue switches, and Voice Generator with Service and Queue switches. The header shows the app name and online count. Shared Service/Queue column headings, compact switches and health dots keep the three rows narrow. Each row has a settings button; generator rows offer separate Service settings and Queue settings. The menu bar activity glyph and the app icon share the same visual mark.

Green means the service's health API reports a working service. Red means stopped, starting or unhealthy. Hover over a red dot (or click it with a mouse or accessibility tool) to see a tooltip above it with the reason: not started, waiting for startup, not responding, a specific health error, or the most recent startup/exit failure. Startup failures persist across monitor restarts and clear after a successful start or explicit stop. The switch tracks the process separately from health, so an unhealthy running process can still be switched off. Loading/unloaded speech weights are normal when the voice API is otherwise ready. A spinner appears during start/stop operations. Status refreshes every 15 seconds while the popover is expanded and focused, and every 15 minutes while closed or unfocused. Opening the popover, completing a start/stop action, saving settings or choosing Refresh status refreshes immediately. The polling timer is rescheduled when visibility or focus changes, so the hidden app does not wake up at the foreground rate.

## Installed location

- App: `~/Applications/Daemon Monitor.app`
- Source: `~/Documents/Widgets/DaemonMonitor`
- Login agent: `~/Library/LaunchAgents/local.daemonmonitor.app.plist`
- Saved settings and active process records: `~/Library/Application Support/DaemonMonitor`
- Monitor-launched service logs: `~/Library/Application Support/DaemonMonitor/logs`

The app launches at login and has no Dock icon. Right-click its menu bar icon for Refresh, Open logs and Quit. Quitting the monitor leaves all five services in their current state. Command-drag the menu bar icon to reposition it.

## Startup settings

Click a row’s settings button. For generators, choose Service settings or Queue settings. Back discards unsaved edits; Save stores validated settings for the next explicit start. The startup form aligns labels and controls in two columns; Paths & environment expands the project/state folder, executable and environment controls. Saving never restarts a service. Running services remain monitored at their actual endpoint until stopped, even when you save another port or folder.

| Service | Startup controls | Initial defaults |
| --- | --- | --- |
| ai-bridge | State folder (`--home`), executable, port, file-only logging, environment | Installed `local.ai-bridge.api` login service, 8765 |
| Image gen service | Project folder, model, port, queue port, prompt expansion, LoRAs, environment | Z-Image Turbo, 5732, queue 55302, LLM and LoRAs enabled |
| Image gen queue | Project folder, port, environment | 55302 |
| Voice gen service | Project folder, model/backend, port, queue port, prompt expansion, environment | Higgs, 5743, queue 55205, LLM enabled |
| Voice gen queue | Project folder, port, environment | 55205 |

Image choices: Z-Image Turbo, Chroma1-HD and Chroma1-Flash. Voice choices: Higgs, VoxCPM2, Qwen3-TTS, Chatterbox, IndexTTS, MOSS and Fish. Selecting a model requires its already-installed runtime and assets. Startup never runs setup/download commands. Missing external volumes and startup errors appear in the popover, with details in the logs.

Environment overrides accept literal `KEY=value` entries, one per line. They cover the tools' additional documented environment-based startup options, for example `DATA_DIR`, `OUTPUT_DIR`, `WEIGHTS_DIR`, `GPU_LOCK_FILE`, `PROMPT_LLM_DIR`, `VENV` and `QUEUE_PYTHON`. Empty lines and lines starting with `#` are ignored. Values are passed as environment strings without shell evaluation, quote removal, variable expansion or command substitution. Use absolute paths in values. Named options (`MODEL`, `PORT`, `QUEUE_PORT`, `NO_LLM`, `NO_LORAS`) and `HOME`/`PATH` cannot be overridden here. Existing project `storage.json` and runtime choices remain authoritative unless explicitly overridden.

A generator and its queue share a project folder; saving the folder updates both. The generator's Queue port and the queue's Port also edit the same saved value. All five ports must be distinct and between 1024 and 65535. Stop a running queue before starting a generator against a newly configured queue port/folder.

## Service behavior

Image and voice start through their existing noninteractive `make serve` launchers, preserving readiness checks, model selection, storage and startup modes. Their existing launchers also start/reuse the corresponding queue. Queue switches independently start/stop the queue HTTP processes; stopping a generator leaves its queue available. Stopping the image queue can make the running image UI's queue routes unavailable until the queue is switched back on. No job cancellation, clearing or deletion is performed.

Generators that are busy refuse an off request and show a message to wait for the current job. Idle generators and queue APIs receive SIGTERM only after checking the Python command, project working directory, port and process identity. Processes on other test ports or from other checkouts are ignored. No force-kill is used. A service that fails to become ready within four minutes remains visible for inspection; the monitor does not repeatedly restart it.

ai-bridge is controlled through its existing login agent and authenticated local `/health` and `/v1/shutdown` API. The token is read locally from the selected state folder and never included in UI, configuration, process arguments or logs. Switching it off invokes its normal API shutdown, which also stops active bridge provider subprocesses. Changing bridge startup settings updates its existing launch-agent arguments/environment only at the next start while stopped, preserving the rest of its login configuration. Its existing behavior starts it at the next login after a clean shutdown.

## Build, install and remove

Requires macOS 13+ on Apple Silicon, Xcode command line tools, and Python 3.9+. On this Mac Homebrew Python **3.15.1** is installed at `/opt/homebrew/bin/python3`. The monitor uses it when available and otherwise `/usr/bin/python3`. Each model service still uses its own existing Python environment; they are not upgraded or recreated.

```sh
cd ~/Documents/Widgets/DaemonMonitor
./build.sh
./install.sh
```

The app is compiled with the local Swift SDK and ad hoc signed for this Mac. `install.sh` replaces only the monitor app and its login agent. The previous app bundle is retained as `~/Applications/Daemon Monitor.app.previous` on updates. It does not restart monitored services.

```sh
./uninstall.sh
```

Removal stops/removes only Daemon Monitor and its own login agent. Saved settings, logs and all monitored services/data are retained.

## Diagnostics and verification

```sh
python3 Resources/control.py status
python3 Resources/control.py config
python3 -m unittest discover -s Tests -v
```

`control.py` also accepts `start SERVICE`, `stop SERVICE`, and `save` (JSON patch on standard input). IDs are `bridge`, `image`, `image-queue`, `voice`, `voice-queue`. `--support /absolute/folder` isolates monitor configuration/process records for tests. The lifecycle commands operate the configured services; the unit suite uses mocks and temporary local HTTP fixtures instead.

Automated checks cover startup argument construction, configuration validation, old endpoint retention, literal environment values, authenticated local health requests, independent queue controls, stale PIDs, development ports, busy generators and refusal to replace unrelated listeners. Real startup/health/shutdown checks are recorded in `verification.json`.
