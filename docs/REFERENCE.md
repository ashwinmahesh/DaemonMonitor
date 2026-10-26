# Configuration and developer reference

[Back to the user guide](../README.md)

## Startup options

Saved settings take effect on the next explicit start. Running services continue to be monitored at their existing address, even after you save a different port or folder.

| Control | Available options | Defaults |
| --- | --- | --- |
| AI Bridge | State folder (`--home`), executable, port, file-only logging, environment | Existing `local.ai-bridge.api` login service; port 8765 |
| Image service | Project folder, model, port, queue port, prompt LLM, LoRAs, environment | Z-Image Turbo; port 5732; queue 55302; prompt LLM and LoRAs on |
| Image queue | Project folder, port, environment | Port 55302 |
| Voice service | Project folder, model/backend, port, queue port, prompt LLM, environment | Higgs; port 5743; queue 55205; prompt LLM on |
| Voice queue | Project folder, port, environment | Port 55205 |

The default project folders are `~/Documents/models/ImageGen-Service` and `~/Documents/models/VoiceGen-Service`. Set a different folder under **Paths & environment** if needed.

Supported image models are Z-Image Turbo, Chroma1-HD, and Chroma1-Flash. Supported voice backends are Higgs, VoxCPM2, Qwen3-TTS, Chatterbox, IndexTTS, MOSS, and Fish. Each choice requires its runtime and model assets to be installed already. Startup never runs setup or download commands.

A generator and its queue share a project folder and queue port. Saving either value updates both configurations. All five ports must be distinct and between 1024 and 65535. Stop a running queue before starting a generator against a newly configured queue port or folder.

### Environment overrides

Enter one literal `KEY=value` per line. Empty lines and lines starting with `#` are ignored. Values are passed directly to the process: there is no shell evaluation, quote removal, variable expansion, or command substitution. Use absolute paths and leave out shell-style quotes.

These overrides expose additional environment-based options supported by the services, such as `DATA_DIR`, `OUTPUT_DIR`, `WEIGHTS_DIR`, `GPU_LOCK_FILE`, `PROMPT_LLM_DIR`, `VENV`, and `QUEUE_PYTHON`. Existing project `storage.json` and runtime choices remain in effect unless explicitly overridden.

Use the form controls for `MODEL`, `PORT`, `QUEUE_PORT`, `NO_LLM`, and `NO_LORAS`; those keys cannot be overridden here. `HOME` and `PATH` overrides are also rejected.

## Health and service control

Health dots reflect the service’s health API. Switches track processes separately, so a running but unhealthy service can still be switched off. Voice model weights being unloaded or loading is normal when the voice API is otherwise ready.

Hover over a dot, or click it, to see its status. Startup and exit failures are remembered across monitor restarts. They clear after a successful start or an explicit stop. A service that does not become ready within four minutes remains visible for inspection; the monitor does not keep restarting it.

Status refreshes every 15 seconds while the popover is open, active, and focused, or every 15 minutes otherwise. Opening the popover, saving settings, finishing a start/stop action, or requesting a refresh checks status immediately.

### Image and voice

Generators use their existing noninteractive `make serve` launchers. These preserve each project’s readiness checks, model selection, storage, and startup modes, and start or reuse the corresponding queue. Queue switches independently control the queue HTTP processes.

Stopping a generator leaves its queue available. Stopping the image queue can make the running image UI’s queue routes unavailable until the queue starts again. The monitor does not cancel, clear, or delete jobs.

Busy generators refuse stop requests. Idle generators and queues receive SIGTERM only after the monitor checks the Python command, project working directory, port, and process identity. It ignores processes from other checkouts or test ports and does not force-kill them.

### AI Bridge

The bridge uses its existing login agent and authenticated local `/health` and `/v1/shutdown` API. Its token is read from the selected state folder and is never included in the interface, configuration, process arguments, or logs.

Switching it off invokes normal API shutdown, which also stops active bridge provider subprocesses. New startup settings update the existing launch agent’s arguments and environment at the next start while stopped, preserving the rest of its login configuration. The bridge’s existing login behavior can start it again at the next login.

## Local files

| Item | Location |
| --- | --- |
| Installed app | `~/Applications/Daemon Monitor.app` |
| Monitor login agent | `~/Library/LaunchAgents/local.daemonmonitor.app.plist` |
| Settings, process records, and remembered failures | `~/Library/Application Support/DaemonMonitor` |
| Monitor and monitor-launched service logs | `~/Library/Application Support/DaemonMonitor/logs` |
| Seven-day performance history and counter baselines | `~/Library/Application Support/DaemonMonitor/metrics.sqlite3` |

The monitor uses `/opt/homebrew/bin/python3` when available, falling back to `/usr/bin/python3`. The helper requires Python 3.9 or later. The install and uninstall scripts use Homebrew Python explicitly. Each model service continues to use its own existing Python environment.

## Performance collection

`Resources/metrics.py` collects all five service groups without calling health APIs or changing the monitored tools. It identifies the configured processes, follows their live descendants, and treats another monitored service’s root as a boundary so generator and queue usage is not counted twice.

CPU time and physical memory footprint come from Darwin’s `proc_pid_rusage` API, using the public `rusage_info_v2` layout. See Apple’s [resource usage documentation](https://developer.apple.com/documentation/kernel/rusage_info_current). Memory is physical footprint, including compressed allocations, rather than virtual address space or separately added GPU allocations.

On supported Apple Silicon drivers, the GPU collector reads each PID’s `AGXDeviceUserClient` / `AppUsage` / `accumulatedGPUTime` counters from the IORegistry. It calculates execution-time deltas divided by elapsed time. This is process-attributed GPU activity, rather than the whole Mac’s GPU percentage. Parallel command queues can produce values above 100%. Driver counters are not available on every macOS/GPU combination; unavailable or reset counters produce gaps, rather than invented zeroes.

Only running services and queues get metric samples: every 15 seconds with the popover open and focused, or every 60 seconds otherwise. Stopped tools add no zero-usage rows. Lightweight process discovery checks for newly started tools, and the GPU query is skipped entirely when all monitored tools are stopped. Run identifiers keep separate executions disconnected in the charts, even after a short stop or restart.

There is no privileged helper, continuous profiler, additional login agent, or extra Python package. The main app must remain running to collect history. Sampling does not run during sleep. Short-lived child processes or GPU queues that start and finish between samples may be missed.

SQLite stores seven days of samples outside the repository, using WAL transactions and private file permissions. PID start times guard against PID reuse. First intervals, counter resets, and long collection gaps remain unknown. No older history is fabricated. Queries return at most 361 averaged points per graph; range peak labels are calculated from the original samples.

### Measured overhead

Ten end-to-end collections on the development Mac, with AI Bridge and its helper running and both generators stopped, measured a median **100 ms wall time**, **96 ms CPU time**, and **27.6 MiB peak helper memory**, including Python startup and child commands. The helper exits after each collection. This corresponds to about **0.16% of one CPU core** at the background rate, or **0.64%** at the foreground rate; chart rendering is separate, and more live child processes can add work.

A seven-day SQLite fixture for one continuously running tool occupied **1.3 MiB** at one-minute sampling, or **5.2 MiB** at continuous 15-second sampling. Stopped tools do not add rows. These are measured examples, not fixed limits; SQLite’s temporary WAL files also use some space.

## Development

The native interface is in `Sources/DaemonMonitor.swift`, using SwiftUI and an AppKit status item and popover. `Sources/Performance.swift` adds native Swift Charts and sampling coordination; `Sources/main.swift` starts the app. `Resources/control.py` provides service lifecycle and configuration handling, and `Resources/metrics.py` collects and stores metrics using the Python standard library. `Tools/MakeIcon.swift` generates the app icon.

Build without installing:

```sh
./build.sh
```

The build targets Apple Silicon and macOS 13+, uses the local Swift SDK, and ad hoc signs the bundle for local use. `./install.sh` builds and installs the app and its login agent; it does not restart monitored daemons. `./uninstall.sh` removes only the monitor and its agent, retaining saved configuration and logs.

### Control CLI

```sh
python3 Resources/control.py status
python3 Resources/control.py config
python3 Resources/control.py sample
python3 Resources/control.py history image --range 30m
```

The helper also accepts `start SERVICE`, `stop SERVICE`, and `save` with a JSON patch on standard input. Service IDs are `bridge`, `image`, `image-queue`, `voice`, and `voice-queue`. These commands control the configured services.

Use `--support /absolute/folder` to isolate configuration and process records for tests.

### Verification

```sh
python3 -m unittest discover -s Tests -v
zsh Tests/run_monitor_tests.sh
```

The unit suite uses mocks and temporary local HTTP fixtures. It covers startup arguments, configuration validation, retention of running endpoints, literal environment values, authenticated health checks, independent queue controls, stale PIDs, development ports, busy generators, and refusal to replace unrelated listeners.

The native monitor checks simulate delayed helper replies to verify that switches keep their requested position through on/off actions and overlapping polls. They also cover status recovery without hiding action errors, browser links using actual running ports, and tooltip layout, including five-digit queue ports and wrapped failure reasons, without operating real services. Process-query fixtures verify one bounded retry, a readable error after repeated timeouts, and preservation of metrics history when discovery fails.

Metrics fixtures cover process trees, queue boundaries, executable paths containing spaces, CPU/GPU deltas, PID reuse, sleep and counter resets, unknown readings, stopped processes, range aggregation, retention, and private storage. Native checks also exercise stale history responses and sampling throttling.

For lifecycle changes, run the suite and build the app. Inspect the popover and settings on an available Mac. Preserve existing services and jobs during validation; do not submit inference jobs, clear queues, download models, or force-kill services. Record actual manual checks and limitations in the ignored local `verification.json` file.

The screenshots in the README were captured from the installed app. They show the compact status panel and the Image Generator startup form without changing service state.
