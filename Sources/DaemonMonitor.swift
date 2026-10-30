import AppKit
import SwiftUI

struct ServiceStatus: Decodable, Identifiable {
    let id: String
    let name: String
    var running: Bool
    var healthy: Bool
    var detail: String
    let port: Int
    var runtime_model_switching: Bool? = nil
    var active_model: String? = nil
    var busy: Bool? = nil
    // Shared persisted pause flag for a generator family; nil while neither its generator nor queue reports it.
    var queue_paused: Bool? = nil

    var activeModelSummary: String? {
        guard runtime_model_switching == true else { return nil }
        return "Active model: \(active_model ?? "None loaded")"
    }
}

struct ServiceSettings: Codable, Identifiable {
    let id: String
    let name: String
    var port: Int
    var root: String
    var binary: String?
    var llm: Bool?
    var loras: Bool?
    var log_file_only: Bool?
    var environment: String
}

struct Reply: Decodable {
    let ok: Bool
    let error: String?
}
struct StatusReply: Decodable { let services: [ServiceStatus] }
struct ConfigReply: Decodable { let services: [ServiceSettings] }

// Process arguments never pass through a shell. All blocking work stays off the UI thread.
enum Helper {
    typealias Completion = (Result<Data, Error>) -> Void
    typealias Caller = ([String], Data?, @escaping Completion) -> Void

    static func call(_ arguments: [String], input: Data? = nil, completion: @escaping Completion) {
        let script = Bundle.main.resourceURL!.appendingPathComponent("control.py")
        DispatchQueue.global(qos: .utility).async {
            do {
                let process = Process()
                let python = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = ["-B", script.path] + arguments
                let output = Pipe(), errors = Pipe(), stdin = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = stdin
                try process.run()
                if let input { stdin.fileHandleForWriting.write(input) }
                try? stdin.fileHandleForWriting.close()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 280, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                let reply = try? JSONDecoder().decode(Reply.self, from: data)
                guard reply?.ok == true else {
                    let message = reply?.error ?? String(data: errorData, encoding: .utf8) ?? "Could not read service status."
                    throw NSError(domain: "DaemonMonitor", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "The service controller did not respond." : message])
                }
                DispatchQueue.main.async { completion(.success(data)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

final class Monitor: ObservableObject {
    @Published var statuses: [ServiceStatus] = []
    @Published var settings: [ServiceSettings] = []
    @Published var pending: [String: Bool] = [:]
    // Requested pause state per generator while a pause/resume request and its follow-up snapshot are in flight.
    @Published var pausing: [String: Bool] = [:]
    @Published var selectedID: String? {
        didSet {
            if selectedID != nil { performanceID = nil }
            if selectedID != oldValue { settingsExpanded = false }
            layoutChanged?()
        }
    }
    @Published var settingsExpanded = false { didSet { layoutChanged?() } }
    @Published var error: String? { didSet { layoutChanged?() } }
    @Published private(set) var statusError: String? { didSet { layoutChanged?() } }
    var notice: String? { error ?? statusError }
    func dismissNotice() { error = nil; statusError = nil }
    @Published var saving = false
    @Published var performanceID: String? {
        didSet {
            guard performanceID != oldValue else { return }
            performance.select(performanceID)
            layoutChanged?()
        }
    }
    let performance: PerformanceMonitor
    var layoutChanged: (() -> Void)?
    var statusChanged: (() -> Void)?
    private let helper: Helper.Caller
    private var refreshing = false
    private var refreshQueued = false
    private var refreshCompletions: [() -> Void] = []

    init(helper: @escaping Helper.Caller = Helper.call) {
        self.helper = helper
        performance = PerformanceMonitor(helper: helper)
    }

    func showPerformance(_ id: String) { selectedID = nil; performanceID = id }

    func family(_ id: String) -> String { String(id.split(separator: "-")[0]) }
    func isBusy(_ id: String) -> Bool { pending.keys.contains { family($0) == family(id) } }
    func isOn(_ id: String) -> Bool { pending[id] ?? statuses.first(where: { $0.id == id })?.running ?? false }
    func queuePaused(_ id: String) -> Bool? { pausing[id] ?? statuses.first(where: { $0.id == id })?.queue_paused }
    func setProcessing(_ status: ServiceStatus, on: Bool) {
        guard pausing[status.id] == nil, queuePaused(status.id) != nil else { return }
        error = nil
        pausing[status.id] = !on
        helper([on ? "resume" : "pause", status.id], nil) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
            // As with start/stop, hold the requested position until a newer snapshot arrives.
            self.refresh { self.pausing.removeValue(forKey: status.id) }
        }
    }
    func serviceUIURL(_ id: String) -> URL? {
        guard ["image", "voice"].contains(id), let status = statuses.first(where: { $0.id == id }), status.running else { return nil }
        return URL(string: "http://127.0.0.1:\(status.port)/")
    }
    func openServiceUI(_ id: String) {
        guard let url = serviceUIURL(id) else { return }
        if !NSWorkspace.shared.open(url) { error = "Could not open the service UI in your default browser." }
    }
    func loadSettings() {
        helper(["config"], nil) { result in
            switch result {
            case .success(let data):
                do { self.settings = try JSONDecoder().decode(ConfigReply.self, from: data).services }
                catch { self.error = error.localizedDescription }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    func refresh(completion: (() -> Void)? = nil) {
        if let completion { refreshCompletions.append(completion) }
        guard !refreshing else { refreshQueued = true; return }
        refreshing = true
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        helper(["status"], nil) { result in
            switch result {
            case .success(let data):
                do {
                    self.statuses = try JSONDecoder().decode(StatusReply.self, from: data).services
                    self.statusError = nil
                    self.statusChanged?()
                } catch { self.reportStatusError(error.localizedDescription) }
            case .failure(let error):
                self.reportStatusError(error.localizedDescription)
            }
            self.refreshing = false
            completions.forEach { $0() }
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh()
            }
        }
    }
    private func reportStatusError(_ message: String) {
        statusError = message
        for i in statuses.indices {
            statuses[i].healthy = false
            statuses[i].detail = "Status unavailable: " + message
        }
        statusChanged?()
    }
    func toggle(_ status: ServiceStatus, on: Bool) {
        guard !isBusy(status.id) else { return }
        error = nil
        pending[status.id] = on
        helper([on ? "start" : "stop", status.id], nil) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
            // Keep the switch steady until a snapshot requested after the action arrives.
            self.refresh { self.pending.removeValue(forKey: status.id) }
        }
    }
    func save(_ value: ServiceSettings, port: String, queuePort: String?) {
        guard let portValue = Int(port), (1024...65535).contains(portValue) else {
            error = "Enter a port between 1024 and 65535."; return
        }
        var value = value
        value.port = portValue
        do {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            json.removeValue(forKey: "name")
            if let queuePort {
                guard let number = Int(queuePort), (1024...65535).contains(number) else {
                    error = "Enter a queue port between 1024 and 65535."; return
                }
                json["queue_port"] = number
            }
            let input = try JSONSerialization.data(withJSONObject: json)
            saving = true
            error = nil
            helper(["save"], input) { result in
                self.saving = false
                switch result {
                case .success: self.selectedID = nil; self.loadSettings(); self.refresh()
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func openLogs(_ id: String? = nil) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DaemonMonitor/logs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let id, let item = settings.first(where: { $0.id == id }) {
            let candidate = id == "bridge" ? URL(fileURLWithPath: NSString(string: item.root).expandingTildeInPath).appendingPathComponent("console.log") : folder.appendingPathComponent(id + ".log")
            if FileManager.default.fileExists(atPath: candidate.path) { NSWorkspace.shared.open(candidate); return }
        }
        NSWorkspace.shared.open(folder)
    }
}

// A nonactivating hover panel keeps the main popover focused and polling normally.
// It opens above the dot without resizing or shifting any service rows.
struct StatusDot: NSViewRepresentable {
    let healthy: Bool
    let reason: String
    let port: Int
    var context: String? = nil

    func makeNSView(context: Context) -> HoverDot { HoverDot() }
    func updateNSView(_ view: HoverDot, context: Context) {
        let healthyText = "Running on port \(port)" + (self.context.map { "\n" + $0 } ?? "")
        view.configure(healthy: healthy, reason: healthy ? healthyText : reason)
    }
    static func dismantleNSView(_ view: HoverDot, coordinator: ()) { view.dismissTooltip() }

    static func tooltipLabel(for reason: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: String(reason.prefix(1400)))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        // Measure the actual cell, including its text inset and line height. Measuring
        // only the string can wrap five-digit ports onto a hidden second line.
        let width = min(260, ceil(label.cell!.cellSize.width))
        let fitted = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000))
        label.frame = NSRect(x: 8, y: 6, width: width, height: ceil(fitted.height))
        return label
    }

    final class HoverDot: NSView {
        private var healthy = false
        private var reason = "Not started."
        private var hovered = false
        private var area: NSTrackingArea?
        private var tooltip: NSPanel?
        private var delayedShow: DispatchWorkItem?
        private var focusObserver: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel("Not started.")
            setAccessibilityHelp("Show status details")
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow, window === self.window else { return }
                self.dismissTooltip()
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit {
            delayedShow?.cancel()
            tooltip?.close()
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }
        func configure(healthy: Bool, reason: String) {
            guard self.healthy != healthy || self.reason != reason else { return }
            self.healthy = healthy
            self.reason = reason
            setAccessibilityLabel(reason)
            needsDisplay = true
            dismissTooltip()
            if hovered { scheduleTooltip() }
        }
        override func draw(_ dirtyRect: NSRect) {
            (healthy ? NSColor.systemGreen : NSColor.systemRed).setFill()
            NSBezierPath(ovalIn: NSRect(x: (bounds.width - 8) / 2, y: (bounds.height - 8) / 2, width: 8, height: 8)).fill()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(next)
            area = next
        }
        override func accessibilityPerformPress() -> Bool {
            hovered = true
            showTooltip()
            return true
        }
        override func mouseDown(with event: NSEvent) {
            _ = accessibilityPerformPress()
        }
        override func mouseEntered(with event: NSEvent) {
            hovered = true
            scheduleTooltip()
        }
        override func mouseExited(with event: NSEvent) {
            hovered = false
            dismissTooltip()
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { hovered = false; dismissTooltip() }
            super.viewWillMove(toWindow: newWindow)
        }
        private func scheduleTooltip() {
            delayedShow?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.showTooltip() }
            delayedShow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        private func showTooltip() {
            guard hovered, tooltip == nil, let window, window.isKeyWindow else { return }
            let label = StatusDot.tooltipLabel(for: reason)
            let size = NSSize(width: label.frame.maxX + 8, height: label.frame.maxY + 6)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.level = .popUpMenu
            let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            background.material = .popover
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 7
            background.layer?.masksToBounds = true
            background.addSubview(label)
            panel.contentView = background
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
            let left = max(screen.minX + 6, window.frame.minX + 12)
            let right = min(screen.maxX - 6, window.frame.maxX - 12)
            let origin = NSPoint(x: min(max(anchor.midX - size.width / 2, left), right - size.width),
                                 y: min(anchor.maxY + 7, screen.maxY - size.height - 6))
            panel.setFrameOrigin(origin)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            tooltip = panel
        }
        func dismissTooltip() {
            delayedShow?.cancel()
            if let tooltip {
                tooltip.parent?.removeChildWindow(tooltip)
                tooltip.close()
            }
            tooltip = nil
        }
    }
}

struct ServiceSwitch: View {
    @ObservedObject var monitor: Monitor
    let status: ServiceStatus

    var body: some View {
        Toggle(status.name, isOn: Binding(
            get: { monitor.isOn(status.id) },
            set: { monitor.toggle(status, on: $0) }
        ))
        .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
        .disabled(monitor.isBusy(status.id))
        .accessibilityLabel(status.name)
        .help(status.detail)
    }
}

struct ProcessingSwitch: View {
    @ObservedObject var monitor: Monitor
    let title: String
    let service: ServiceStatus

    private var helpText: String {
        switch monitor.queuePaused(service.id) {
        case false?: return "Processing: waiting jobs run in order. Switch off to pause after the active job finishes. Generate immediately and Run Now jobs still run while paused."
        case true?: return "Paused: waiting jobs stay saved and the active job finishes. Generate immediately and Run Now jobs still run. Switch on to resume."
        case nil: return "Start the generator or its queue to see or change processing."
        }
    }
    var body: some View {
        Toggle("Process \(title) queue", isOn: Binding(
            get: { monitor.queuePaused(service.id) == false },
            set: { monitor.setProcessing(service, on: $0) }
        ))
        .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
        .disabled(monitor.pausing[service.id] != nil || monitor.queuePaused(service.id) == nil)
        .accessibilityLabel("Process \(title) queue")
        .help(helpText)
    }
}

struct RowSettings: View {
    @ObservedObject var monitor: Monitor
    let title: String
    let serviceID: String
    let queueID: String?

    private func open(_ id: String) {
        monitor.error = nil
        monitor.selectedID = id
    }
    var body: some View {
        Group {
            if let queueID {
                Menu {
                    Button("Service settings…") { open(serviceID) }
                    Button("Queue settings…") { open(queueID) }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else {
                Button { open(serviceID) } label: {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }.buttonStyle(.plain)
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 24)
        .help("Startup settings for " + title)
        .accessibilityLabel("Settings for " + title)
    }
}

struct ServiceBrowserButton: View {
    @ObservedObject var monitor: Monitor
    let title: String
    let service: ServiceStatus
    private var helpText: String {
        service.running ? "Open \(title) in your browser" : "Start \(title) to open its UI"
    }
    var body: some View {
        Button { monitor.openServiceUI(service.id) } label: {
            Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                .frame(width: 20, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(monitor.serviceUIURL(service.id) == nil)
            .help(helpText).accessibilityLabel("Open \(title) UI")
    }
}

struct ServiceFamilyRow: View {
    @ObservedObject var monitor: Monitor
    let title: String
    let service: ServiceStatus
    let queue: ServiceStatus?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                StatusDot(healthy: service.healthy, reason: service.detail, port: service.port,
                          context: service.runtime_model_switching == true ? service.detail : nil)
                    .frame(width: 8, height: 20)
                Button { monitor.showPerformance(service.id) } label: {
                    HStack(spacing: 3) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("View performance for " + title).accessibilityLabel("Performance for " + title)
                if queue != nil {
                    ServiceBrowserButton(monitor: monitor, title: title, service: service)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ServiceSwitch(monitor: monitor, status: service)
                .frame(width: 44)
            Group {
                if let queue {
                    HStack(spacing: 4) {
                        StatusDot(healthy: queue.healthy, reason: queue.detail, port: queue.port)
                            .frame(width: 8, height: 20)
                        ServiceSwitch(monitor: monitor, status: queue)
                    }
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }.frame(width: 58)
            Group {
                if queue != nil {
                    ProcessingSwitch(monitor: monitor, title: title, service: service)
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }.frame(width: 60)
            if monitor.pending[service.id] != nil || monitor.pausing[service.id] != nil || (queue.map { monitor.pending[$0.id] != nil } ?? false) {
                ProgressView().controlSize(.mini).frame(width: 20, height: 24)
            } else {
                RowSettings(monitor: monitor, title: title, serviceID: service.id, queueID: queue?.id)
            }
        }.frame(height: 28)
    }
}

struct ErrorNotice: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundStyle(.red).lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }.padding(9).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @State private var value: ServiceSettings
    @State private var port: String
    @State private var queuePort: String
    private var generator: Bool { value.id == "image" || value.id == "voice" }
    private var liveStatus: ServiceStatus? { monitor.statuses.first(where: { $0.id == value.id }) }
    private var title: String {
        if value.id == "bridge" { return "AI Bridge" }
        return value.id.hasPrefix("image") ? "Image Generator" : "Voice Generator"
    }
    private var subtitle: String {
        value.id == "bridge" ? "Startup settings" : value.id.hasSuffix("queue") ? "Queue startup" : "Service startup"
    }
    init(monitor: Monitor, value: ServiceSettings) {
        self.monitor = monitor
        _value = State(initialValue: value)
        _port = State(initialValue: String(value.port))
        _queuePort = State(initialValue: String(monitor.settings.first(where: { $0.id == value.id + "-queue" })?.port ?? 0))
    }
    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 22)
    }
    private func pathRow(_ title: String, _ binding: Binding<String>) -> some View {
        formRow(title) {
            TextField(title, text: binding).labelsHidden().textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced)).controlSize(.small)
                .help(binding.wrappedValue)
        }
    }
    private func portRow(_ title: String, _ binding: Binding<String>) -> some View {
        formRow(title) {
            TextField(title, text: binding).labelsHidden().textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced)).controlSize(.small).frame(width: 72)
        }
    }
    private func flagRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        formRow(title) {
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
                .accessibilityLabel(title)
        }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { monitor.error = nil; monitor.selectedID = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium)).frame(width: 18, height: 28)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Back to services")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        portRow("Port", $port)
                        if generator {
                            portRow("Queue port", $queuePort)
                            flagRow("Prompt LLM", Binding(get: { value.llm ?? true }, set: { value.llm = $0 }))
                            if value.id == "image" {
                                flagRow("LoRAs", Binding(get: { value.loras ?? true }, set: { value.loras = $0 }))
                            }
                        }
                        if value.id == "bridge" {
                            flagRow("File logging", Binding(get: { value.log_file_only ?? true }, set: { value.log_file_only = $0 }))
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    if let summary = liveStatus?.activeModelSummary {
                        Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).help(liveStatus?.detail ?? summary)
                    }
                    DisclosureGroup(isExpanded: $monitor.settingsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            pathRow(value.id == "bridge" ? "State folder" : "Project", $value.root)
                            if value.id == "bridge" {
                                pathRow("Executable", Binding(get: { value.binary ?? "" }, set: { value.binary = $0 }))
                            }
                            Text("Environment overrides").font(.system(size: 11, weight: .medium)).padding(.top, 2)
                            TextEditor(text: $value.environment).font(.system(size: 11, design: .monospaced))
                                .scrollContentBackground(.hidden).padding(5).frame(height: 70)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2)))
                                .accessibilityLabel("Environment overrides")
                            Text("KEY=value, one per line. Values are literal.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.top, 8).padding(.horizontal, 10)
                    } label: {
                        Text("Paths & environment").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    if let error = monitor.error { ErrorNotice(text: error) { monitor.error = nil } }
                }.padding(.top, 1)
            }.scrollIndicators(.never)
            HStack(spacing: 8) {
                Button("Logs") { monitor.openLogs(value.id) }.buttonStyle(.borderless).controlSize(.small)
                Spacer()
                Text("Applies on next start").font(.system(size: 10)).foregroundStyle(.secondary)
                if monitor.saving { ProgressView().controlSize(.mini) }
                Button("Save") { monitor.save(value, port: port, queuePort: generator ? queuePort : nil) }
                    .keyboardShortcut(.defaultAction).controlSize(.small)
                    .disabled(monitor.saving || monitor.isBusy(value.id))
            }
        }.padding(14)
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    var openRecovery: (() -> Void)? = nil
    var body: some View {
        Group {
            if let id = monitor.performanceID {
                PerformanceView(monitor: monitor, performance: monitor.performance, identifier: id)
            } else if let id = monitor.selectedID, let value = monitor.settings.first(where: { $0.id == id }) {
                SettingsView(monitor: monitor, value: value).id(id)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.accentColor)
                        Text("Daemon Monitor").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(monitor.statuses.filter(\.healthy).count)/5 online")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        Button { monitor.refresh() } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium)).frame(width: 18, height: 20)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh status").accessibilityLabel("Refresh status")
                    }.contextMenu {
                        if let openRecovery { Button("Menu bar recovery…", action: openRecovery) }
                    }
                    Divider()
                    if monitor.statuses.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 2) {
                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                Text("Service").frame(width: 44)
                                Text("Queue").frame(width: 58)
                                Text("Processing").frame(width: 60)
                                Color.clear.frame(width: 20, height: 1)
                            }.font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 12)
                            VStack(spacing: 0) {
                                if let bridge = monitor.statuses.first(where: { $0.id == "bridge" }) {
                                    ServiceFamilyRow(monitor: monitor, title: "AI Bridge", service: bridge, queue: nil)
                                }
                                if let image = monitor.statuses.first(where: { $0.id == "image" }),
                                   let queue = monitor.statuses.first(where: { $0.id == "image-queue" }) {
                                    ServiceFamilyRow(monitor: monitor, title: "Image Generator", service: image, queue: queue)
                                }
                                if let voice = monitor.statuses.first(where: { $0.id == "voice" }),
                                   let queue = monitor.statuses.first(where: { $0.id == "voice-queue" }) {
                                    ServiceFamilyRow(monitor: monitor, title: "Voice Generator", service: voice, queue: queue)
                                }
                            }
                        }
                        if let error = monitor.notice { ErrorNotice(text: error) { monitor.dismissNotice() } }
                    }
                }.padding(12)
            }
        }
    }
}

extension Monitor {
    var contentSize: NSSize {
        if let id = performanceID {
            return NSSize(width: 400, height: family(id) == "bridge" ? 474 : 506)
        }
        if let id = selectedID {
            let base: CGFloat = id == "image" ? 274 : id == "voice" ? 244 : id == "bridge" ? 218 : 188
            let extra: CGFloat = settingsExpanded ? (id == "bridge" ? 188 : 160) : 0
            let modelInfo: CGFloat = statuses.first(where: { $0.id == id })?.activeModelSummary == nil ? 0 : 32
            return NSSize(width: 360, height: base + extra + modelInfo + (error == nil ? 0 : 76))
        }
        return NSSize(width: 388, height: notice == nil ? 160 : 244)
    }
}

final class MenuBarPlacement {
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    var autosaveName: String {
        let revision = preferences.integer(forKey: "MenuBarPlacementRevision")
        return revision > 0 ? "DaemonMonitor-\(revision)" : "DaemonMonitor"
    }
    func reset() {
        let revision = preferences.integer(forKey: "MenuBarPlacementRevision")
        preferences.set(revision < Int.max ? max(1, revision + 1) : 1, forKey: "MenuBarPlacementRevision")
    }
}

struct ControlWindowView: View {
    @ObservedObject var monitor: Monitor
    let resetIcon: () -> Void
    let copyDiagnostics: () -> Void
    let openLogs: () -> Void
    let quit: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            PopoverView(monitor: monitor).frame(width: monitor.contentSize.width, height: monitor.contentSize.height)
            Divider()
            HStack(spacing: 10) {
                Button("Reset icon position", action: resetIcon)
                    .help("Register a fresh menu bar position for Daemon Monitor")
                Spacer(minLength: 0)
                Button("Copy diagnostics", action: copyDiagnostics)
                Menu {
                    Button("Open logs", action: openLogs)
                    Button("Quit Daemon Monitor", action: quit)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options")
            }.font(.system(size: 10)).buttonStyle(.plain).padding(.horizontal, 12).frame(height: 34)
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

final class MonitorPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

struct MenuBarAttachment {
    let itemVisible: Bool
    let hasButton: Bool
    let hasWindow: Bool
    let hasUsableSize: Bool
    let displayID: UInt32?
    let currentDisplayIDs: Set<UInt32>

    var needsRebuild: Bool {
        guard hasButton, hasWindow, hasUsableSize, let displayID else { return true }
        return !currentDisplayIDs.contains(displayID)
    }
    var needsRecovery: Bool { !itemVisible || needsRebuild }
    func canPresentPopover(buttonFrame: NSRect?, screenFrame: NSRect?, menuAreas: [NSRect] = []) -> Bool {
        guard !needsRecovery, let buttonFrame, !buttonFrame.isEmpty, let screenFrame,
              screenFrame.insetBy(dx: -1, dy: -1).contains(buttonFrame) else { return false }
        // A status item can be logically visible while its saved position lies
        // outside the unobscured portions of a notched display's menu bar.
        return menuAreas.isEmpty || menuAreas.contains {
            buttonFrame.minX >= $0.minX - 1 && buttonFrame.maxX <= $0.maxX + 1
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor()
    private let menuBarPlacement = MenuBarPlacement()
    private var controlWindow: MonitorPanel?
    private var timer: Timer?
    private var pollingInterval: TimeInterval?
    private var focusObservers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusVisibility: NSKeyValueObservation?
    private var statusRecovery: DispatchWorkItem?
    private var statusWatchdog: Timer?
    private var statusRecoveryGeneration = 0
    private var pendingStatusRebuild = false
    private var sessionInactive = false
    private var widgetPresentationGeneration = 0
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.daemonmonitor")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        NSLog("Daemon Monitor %@ (%@); %@; pid=%d", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
              ProcessInfo.processInfo.operatingSystemVersionString, ProcessInfo.processInfo.processIdentifier)
        restoreStatusItem(reason: "launch")
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor,
            openRecovery: { [weak self] in self?.showControlWindow() }))
        resize()
        monitor.layoutChanged = { [weak self] in DispatchQueue.main.async { self?.resize() } }
        monitor.statusChanged = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = "Daemon Monitor — \(self.monitor.statuses.filter(\.healthy).count) of 5 healthy"
        }
        monitor.loadSettings()
        monitor.refresh()
        monitor.performance.sample()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self,
                      let window = notification.object as? NSWindow,
                      window === self.popover.contentViewController?.view.window || window === self.controlWindow else { return }
                self.updatePollingSchedule()
            })
        }
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleStatusRecovery(reason: "display change", rebuild: true)
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionInactive = false
                self?.scheduleStatusRecovery(reason: "wake or unlock", rebuild: true)
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionInactive = true
                self?.cancelStatusRecovery()
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkStatusItem(reason: "space change")
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if ["com.apple.SystemUIServer", "com.apple.controlcenter"].contains(application?.bundleIdentifier ?? "") {
                self?.scheduleStatusRecovery(reason: "menu bar host relaunched", rebuild: true)
            }
        })
        // Only inspect local AppKit objects here; no service/process/network polling.
        let watchdog = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.checkStatusItem(reason: "attachment check") }
        watchdog.tolerance = 15
        RunLoop.main.add(watchdog, forMode: .common)
        statusWatchdog = watchdog
        scheduleStatusRecovery(reason: "launch verification")
        updatePollingSchedule()
        // Login startup stays in the background; an explicit launch must remain
        // usable even when macOS does not expose the status item.
        if !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async { [weak self] in self?.showWidget(reason: "explicit launch") }
        }
    }
    private var canPresentPopover: Bool {
        guard let button = statusItem?.button, let window = button.window, window.isVisible,
              let screen = window.screen else { return false }
        return statusAttachment.canPresentPopover(buttonFrame: window.convertToScreen(button.convert(button.bounds, to: nil)),
            screenFrame: screen.frame, menuAreas: [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 })
    }
    private var statusAttachment: MenuBarAttachment {
        let window = statusItem?.button?.window
        return MenuBarAttachment(itemVisible: statusItem?.isVisible == true,
            hasButton: statusItem?.button != nil, hasWindow: window != nil,
            hasUsableSize: !NSMenu.menuBarVisible() || (window.map { $0.frame.width > 0 && $0.frame.height > 0 } ?? false),
            displayID: (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
            currentDisplayIDs: Set(NSScreen.screens.compactMap {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }))
    }
    private func logStatusAttachment(_ reason: String) {
        let state = statusAttachment
        NSLog("Menu bar item (%@): visible=%d button=%d window=%d size=%d display=%@ currentDisplays=%@ frame=%@", reason,
              state.itemVisible ? 1 : 0, state.hasButton ? 1 : 0, state.hasWindow ? 1 : 0,
              state.hasUsableSize ? 1 : 0,
              state.displayID.map(String.init) ?? "none", state.currentDisplayIDs.sorted().map(String.init).joined(separator: ","),
              statusItem?.button?.window.map { NSStringFromRect($0.frame) } ?? "none")
    }
    private func checkStatusItem(reason: String) {
        guard !terminating, !sessionInactive, statusRecovery == nil else { return }
        if statusAttachment.needsRecovery { scheduleStatusRecovery(reason: reason) }
    }
    private func restoreStatusItem(reason: String, rebuild: Bool = false) {
        guard !terminating else { return }
        if rebuild || statusAttachment.needsRebuild {
            // A popover must not retain a removed status button as its anchor.
            if popover.isShown {
                let animates = popover.animates
                popover.animates = false
                popover.performClose(nil)
                popover.animates = animates
            }
            statusVisibility?.invalidate()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = NSStatusItem.AutosaveName(menuBarPlacement.autosaveName)
            item.behavior = []
            statusItem = item
            statusVisibility = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
                if change.newValue == false { self?.scheduleStatusRecovery(reason: "visibility changed") }
            }
        }
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Daemon Monitor")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 17, height: 16)
            button.target = self
            button.action = #selector(clickStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Daemon Monitor — \(monitor.statuses.filter(\.healthy).count) of 5 healthy"
            button.setAccessibilityLabel("Daemon Monitor")
            button.setAccessibilityIdentifier("DaemonMonitor")
            button.needsDisplay = true
        }
        logStatusAttachment(reason)
    }
    private func cancelStatusRecovery() {
        statusRecoveryGeneration += 1
        statusRecovery?.cancel()
        statusRecovery = nil
        pendingStatusRebuild = false
    }
    private func scheduleStatusRecovery(reason: String, rebuild: Bool = false) {
        guard !terminating, !sessionInactive else { return }
        pendingStatusRebuild = pendingStatusRebuild || rebuild
        statusRecoveryGeneration += 1
        let generation = statusRecoveryGeneration
        statusRecovery?.cancel()
        let recovery = DispatchWorkItem { [weak self] in
            guard let self, !self.terminating, !self.sessionInactive, generation == self.statusRecoveryGeneration else { return }
            let rebuild = self.pendingStatusRebuild
            self.pendingStatusRebuild = false
            self.restoreStatusItem(reason: reason, rebuild: rebuild)
            self.verifyStatusAttachment(reason: reason, generation: generation, attempt: 0)
        }
        statusRecovery = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: recovery)
    }
    private func verifyStatusAttachment(reason: String, generation: Int, attempt: Int) {
        let delays: [TimeInterval] = [0.5, 2, 5]
        let verification = DispatchWorkItem { [weak self] in
            guard let self, !self.terminating, !self.sessionInactive, generation == self.statusRecoveryGeneration else { return }
            if self.statusAttachment.needsRecovery {
                self.restoreStatusItem(reason: reason + " retry \(attempt + 1)", rebuild: true)
                if attempt + 1 < delays.count {
                    self.verifyStatusAttachment(reason: reason, generation: generation, attempt: attempt + 1)
                    return
                }
            }
            self.statusRecovery = nil
        }
        statusRecovery = verification
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt], execute: verification)
    }
    private func updatePollingSchedule() {
        let focused = NSApp.isActive && ((popover.isShown && popover.contentViewController?.view.window?.isKeyWindow == true)
            || (controlWindow?.isVisible == true && controlWindow?.isKeyWindow == true))
        monitor.performance.setSampling(focused: focused)
        let interval: TimeInterval = focused ? 15 : 15 * 60
        guard pollingInterval != interval else { return }
        timer?.invalidate()
        pollingInterval = interval
        let nextTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.monitor.refresh()
        }
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }
    private func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismissWidget()
        }
    }
    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
    private func resize() {
        popover.contentSize = monitor.contentSize
        if let window = controlWindow {
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: monitor.contentSize.width, height: monitor.contentSize.height + 35))
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
            window.setFrame(window.constrainFrameRect(window.frame, to: window.screen), display: window.isVisible)
        }
    }
    private func showControlWindow() {
        guard !terminating else { return }
        widgetPresentationGeneration += 1
        popover.performClose(nil)
        if controlWindow == nil {
            let panel = MonitorPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 195)),
                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = "Daemon Monitor"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.delegate = self
            panel.dismiss = { [weak self] in self?.dismissWidget() }
            panel.contentViewController = NSHostingController(rootView: ControlWindowView(monitor: monitor,
                resetIcon: { [weak self] in self?.resetIconPosition() },
                copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
                openLogs: { [weak self] in self?.monitor.openLogs() }, quit: { NSApp.terminate(nil) }))
            controlWindow = panel
        }
        resize()
        if let window = controlWindow, let screen = NSScreen.main ?? NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 12,
                                          y: screen.visibleFrame.maxY - window.frame.height - 8))
        }
        monitor.refresh()
        monitor.loadSettings()
        monitor.performance.sample()
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
        watchOutsideClicks()
        updatePollingSchedule()
        logStatusAttachment("control window opened")
    }
    private func hideControlWindow() {
        controlWindow?.orderOut(nil)
        if !popover.isShown { stopWatchingOutsideClicks() }
        updatePollingSchedule()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === controlWindow { dismissWidget(); return false }
        return true
    }
    private func dismissWidget() {
        widgetPresentationGeneration += 1
        popover.performClose(nil)
        hideControlWindow()
    }
    private func showWidget(reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        if popover.isShown && canPresentPopover {
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        cancelStatusRecovery()
        restoreStatusItem(reason: reason, rebuild: statusAttachment.needsRecovery)
        widgetPresentationGeneration += 1
        presentWidget(generation: widgetPresentationGeneration, attempt: 0, reason: reason)
    }
    private func presentWidget(generation: Int, attempt: Int, reason: String) {
        guard !terminating, generation == widgetPresentationGeneration else { return }
        if canPresentPopover {
            showPopover()
            if !popover.isShown { showControlWindow() }
        } else if attempt < 2 {
            if attempt == 1 { restoreStatusItem(reason: reason + " anchor recovery", rebuild: true) }
            // Newly registered status buttons need a run loop before anchoring.
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.3 : 0.5)) { [weak self] in
                self?.presentWidget(generation: generation, attempt: attempt + 1, reason: reason)
            }
        } else {
            showControlWindow()
        }
    }
    private func resetIconPosition() {
        cancelStatusRecovery()
        menuBarPlacement.reset()
        restoreStatusItem(reason: "user reset icon position", rebuild: true)
        scheduleStatusRecovery(reason: "verify reset position")
    }
    private func copyDiagnostics() {
        let state = statusAttachment
        let displays = NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "none"
            return "Display \(id): \(NSStringFromRect(screen.frame)); right menu area=\(screen.auxiliaryTopRightArea.map(NSStringFromRect) ?? "none")"
        }.joined(separator: "\n")
        let text = """
        Daemon Monitor \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        Menu bar visible: \(NSMenu.menuBarVisible()); placement: \(menuBarPlacement.autosaveName)
        Item visible: \(state.itemVisible); button: \(state.hasButton); window: \(state.hasWindow); size: \(state.hasUsableSize)
        Item display: \(state.displayID.map(String.init) ?? "none"); current displays: \(state.currentDisplayIDs.sorted())
        Item frame: \(statusItem?.button?.window.map { NSStringFromRect($0.frame) } ?? "none")
        \(displays)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func clickStatusItem(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if popover.isShown { dismissWidget() } else { showWidget(reason: "menu bar click") }
    }
    private func showPopover() {
        guard let button = statusItem.button else { return }
        hideControlWindow()
        monitor.refresh()
        monitor.loadSettings()
        monitor.performance.sample()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        updatePollingSchedule()
    }
    private func showMenu() {
        dismissWidget()
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh status", action: #selector(refreshStatus), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open logs", action: #selector(openLogs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Menu bar recovery…", action: #selector(openRecovery), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Daemon Monitor", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc private func refreshStatus() { monitor.refresh() }
    @objc private func openLogs() { monitor.openLogs() }
    @objc private func openRecovery() { showControlWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    func popoverDidShow(_ notification: Notification) {
        watchOutsideClicks()
        updatePollingSchedule()
    }
    func popoverDidClose(_ notification: Notification) {
        widgetPresentationGeneration += 1
        if controlWindow?.isVisible != true { stopWatchingOutsideClicks() }
        updatePollingSchedule()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        checkStatusItem(reason: "application activated")
        updatePollingSchedule()
    }
    func applicationDidResignActive(_ notification: Notification) {
        dismissWidget()
        updatePollingSchedule()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWidget(reason: "reopen")
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        widgetPresentationGeneration += 1
        cancelStatusRecovery()
        statusWatchdog?.invalidate()
        statusVisibility?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        monitor.performance.stop()
        stopWatchingOutsideClicks()
        timer?.invalidate()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
