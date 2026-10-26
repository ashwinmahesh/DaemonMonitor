# Configuration and developer reference

[Back to the user guide](../README.md)

## Startup options

Saved settings take effect on the next explicit start. Running services continue to be monitored at their existing address, even after you save a different port or folder.

| Control | Available options | Defaults |
| --- | --- | --- |
| AI Bridge | State folder (`--home`), executable, port, file-only logging, environment | Existing `local.ai-bridge.api` login service; port 8765 |
| Image service | Project folder, port, queue port, prompt LLM, LoRAs, environment | Port 5742; queue 55302; prompt LLM and LoRAs on |
| Image queue | Project folder, port, environment | Port 55302 |
| Voice service | Project folder, port, queue port, prompt LLM, environment | Port 5743; queue 55205; prompt LLM on |
| Voice queue | Project folder, port, environment | Port 55205 |

The default project folders are `~/Documents/models/ImageGen-Service` and `~/Documents/models/VoiceGen-Service`. Set a different folder under **Paths & environment** if needed.

Saved port overrides stay in effect when defaults change, including an explicitly saved Image service port of 5732. Running services keep their recorded endpoint until they stop.

Generators select and load models at runtime for each job. The monitor has no model picker, model registry, or default-model configuration, and never passes `MODEL` to `make serve`. Obsolete monitor model values are ignored and removed from configuration on the next save. Startup never runs setup or downloads; saving monitor settings never switches a backend or restarts a running service.

A generator and its queue share a project folder and queue port. Saving either value updates both configurations. All five ports must be distinct and between 1024 and 65535. Stop a running queue before starting a generator against a newly configured queue port or folder.

### Environment overrides

Enter one literal `KEY=value` per line. Empty lines and lines starting with `#` are ignored. Values are passed directly to the process: there is no shell evaluation, quote removal, variable expansion, or command substitution. Use absolute paths and leave out shell-style quotes.

These overrides expose additional environment-based options supported by the services, such as `DATA_DIR`, `OUTPUT_DIR`, `WEIGHTS_DIR`, `GPU_LOCK_FILE`, `PROMPT_LLM_DIR`, `VENV`, and `QUEUE_PYTHON`. Existing project `storage.json` and runtime choices remain in effect unless explicitly overridden.

Use the form controls for `PORT`, `QUEUE_PORT`, `NO_LLM`, and `NO_LORAS`; those keys cannot be overridden here. `HOME` and `PATH` overrides are also rejected. Model-selection keys (`MODEL`, `IMAGE_MODEL`, `MODEL_BACKEND`, `DEFAULT_MODEL`) are rejected in overrides and stripped from the generator/queue's inherited environment so they cannot pin a runtime model.

## Health and service control

Health dots reflect the service’s health API. Switches track processes separately. Model weights being unloaded, loading, switching, or processing a job is normal while the generator API and queue storage are healthy. A failed earlier job or a waiting job blocked by missing assets does not by itself turn the entire generator red. Storage and consumer failures do.

Hover over a dot, or click it, to see its status. Startup and exit failures are remembered across monitor restarts. They clear after a successful start or an explicit stop. A service that does not become ready within four minutes remains visible for inspection; the monitor does not keep restarting it.

Status refreshes every 15 seconds while the popover is open, active, and focused, or every 15 minutes otherwise. Opening the popover, saving settings, finishing a start/stop action, or requesting a refresh checks status immediately.

### Image and voice

Generators use their existing noninteractive `make serve` launchers and preserve each project's ready-model preflight, storage, and startup options. `NO_LLM=0` keeps prompt expansion on; `NO_LLM=1` opts out. One generator consumes all eligible models from one project-local durable queue. The queue switch independently controls its lightweight CRUD HTTP API; it does not switch model queues or workers.

Stopping a generator leaves its queue available. A running generator reads and writes the shared SQLite queue directly, so its UI and job routes keep working while the standalone queue HTTP service is off. The monitor never migrates, cancels, clears, or deletes jobs or media.

Health checks follow each project's published contract. Both generators report `runtime_model_switching: true` and `queue_scope: shared`; both queues report the same shared scope.

| Service | `service` | Version field | Project field | Role or mode |
| --- | --- | --- | --- | --- |
| Image generator | `imagegen-generator` | `version` | `project_dir` | Optional `role: generator` |
| Image queue | `imagegen-queue` | `version` | `project_dir` | — |
| Voice generator | `voicegen-service` | `api_version` | `project` | `mode: generator` |
| Voice queue | `voicegen-queue` | `api_version` | `project` | `role: queue-crud` |

Version values must be numeric dotted strings, such as `4.0.0`, and the project must match the configured checkout. Model-bound health contracts and identity aliases are not supported. A service/project mismatch with a working VoiceGen `/health` can indicate an outdated monitor; update Daemon Monitor rather than changing the service's identity fields.

`active_model` is nullable and describes the selected/loaded backend. It is read-only information in generator tooltips and startup settings, and is never used to identify a process. Global queue counts, stage, and a blocked reason appear in the tooltip when supplied.

Busy generators refuse stop requests, including model loading, switching, expansion and preview work. The monitor rechecks health before stopping and refuses to terminate a runtime generator whose idle state cannot be confirmed. Idle generators and queues receive SIGTERM only after checks of the Python command, project working directory, port, and process identity. Processes from other checkouts or test ports are ignored; termination is never forced.

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

Each chart keeps the latest reading immediately to the left of Peak, labeled Now for running tools or Last for stopped tools. Hovering, clicking, or dragging inside the plot centers the nearest sample's value in the header, marks it on the line, and shows its timestamp below. Selection preserves unavailable measurements and gaps between runs; it does not borrow values from a distant sample.

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

The menu item has a stable `DaemonMonitor` autosave name and stays visible independently of the popover. Visibility observation and wake/session/display notifications coalesce recovery work without an extra polling timer. Reopening a closed popover rebuilds the item and waits briefly for AppKit to attach the new anchor before opening; reopening an already visible popover keeps its anchor. Recovery observations and pending work are cleared on termination. The app log records recovery events, but `NSStatusItem.isVisible` cannot prove an item is unobscured when the menu bar runs out of space.

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

Metrics fixtures cover process trees, queue boundaries, executable paths containing spaces, CPU/GPU deltas, PID reuse, sleep and counter resets, unknown readings, stopped processes, range aggregation, retention, and private storage. Native checks also exercise stale history responses, sampling throttling, and chart sample selection across missing measurements, run boundaries, and long gaps.

Runtime-model fixtures cover strict service/project/protocol identity, changing or null active models, blocked jobs, storage failures, removal of obsolete model overrides, model-free startup arguments/environment, busy/preview shutdown protection, and backend-child replacement without restarting performance history. They do not load model weights or submit real inference jobs.

For lifecycle changes, run the suite and build the app. Inspect the popover and settings on an available Mac. Preserve existing services and jobs during validation; do not submit inference jobs, clear queues, download models, or force-kill services. Record actual manual checks and limitations in the ignored local `verification.json` file.

The screenshots in the README were captured from the installed app. They show the compact status panel, AI Bridge performance history, and the Image Generator startup form without changing service state.
