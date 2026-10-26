import AppKit
import SwiftUI

struct ServiceStatus: Decodable, Identifiable {
    let id: String
    let name: String
    var running: Bool
    var healthy: Bool
    var detail: String
    let port: Int
}

struct ServiceSettings: Codable, Identifiable {
    let id: String
    let name: String
    var port: Int
    var root: String
    var model: String?
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
    static func call(_ arguments: [String], input: Data? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        let script = Bundle.main.resourceURL!.appendingPathComponent("control.py")
        DispatchQueue.global(qos: .utility).async {
            do {
                let process = Process()
                let python = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script.path] + arguments
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
    @Published var selectedID: String? {
        didSet {
            if selectedID != oldValue { settingsExpanded = false }
            layoutChanged?()
        }
    }
    @Published var settingsExpanded = false { didSet { layoutChanged?() } }
    @Published var error: String? { didSet { layoutChanged?() } }
    @Published var saving = false
    var layoutChanged: (() -> Void)?
    var statusChanged: (() -> Void)?
    private var refreshing = false

    func family(_ id: String) -> String { String(id.split(separator: "-")[0]) }
    func isBusy(_ id: String) -> Bool { pending.keys.contains { family($0) == family(id) } }
    func loadSettings() {
        Helper.call(["config"]) { result in
            switch result {
            case .success(let data):
                do { self.settings = try JSONDecoder().decode(ConfigReply.self, from: data).services }
                catch { self.error = error.localizedDescription }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Helper.call(["status"]) { result in
            self.refreshing = false
            switch result {
            case .success(let data):
                do { self.statuses = try JSONDecoder().decode(StatusReply.self, from: data).services; self.statusChanged?() }
                catch { self.error = error.localizedDescription }
            case .failure(let error):
                self.error = error.localizedDescription
                for i in self.statuses.indices {
                    self.statuses[i].healthy = false
                    self.statuses[i].detail = "Status unavailable: " + error.localizedDescription
                }
            }
        }
    }
    func toggle(_ status: ServiceStatus, on: Bool) {
        guard !isBusy(status.id) else { return }
        error = nil
        pending[status.id] = on
        Helper.call([on ? "start" : "stop", status.id]) { result in
            self.pending.removeValue(forKey: status.id)
            if case .failure(let error) = result { self.error = error.localizedDescription }
            self.refresh()
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
            Helper.call(["save"], input: input) { result in
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

    func makeNSView(context: Context) -> HoverDot { HoverDot() }
    func updateNSView(_ view: HoverDot, context: Context) { view.configure(healthy: healthy, reason: reason) }
    static func dismantleNSView(_ view: HoverDot, coordinator: ()) { view.dismissTooltip() }

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
            setAccessibilityLabel(healthy ? "Healthy" : reason)
            needsDisplay = true
            dismissTooltip()
            if hovered && !healthy { scheduleTooltip() }
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
            guard !healthy else { return false }
            hovered = true
            showTooltip()
            return true
        }
        override func mouseDown(with event: NSEvent) {
            _ = accessibilityPerformPress()
        }
        override func mouseEntered(with event: NSEvent) {
            hovered = true
            if !healthy { scheduleTooltip() }
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
            guard hovered, !healthy, tooltip == nil, let window, window.isKeyWindow else { return }
            let font = NSFont.systemFont(ofSize: 11)
            let text = String(reason.prefix(1400))
            let measured = (text as NSString).boundingRect(with: NSSize(width: 260, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let size = NSSize(width: max(120, ceil(measured.width)) + 20, height: ceil(measured.height) + 18)
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
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = .labelColor
            label.frame = NSRect(x: 10, y: 9, width: size.width - 20, height: size.height - 18)
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
            get: { monitor.pending[status.id] ?? status.running },
            set: { monitor.toggle(status, on: $0) }
        ))
        .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
        .disabled(monitor.isBusy(status.id))
        .accessibilityLabel(status.name)
        .help(status.detail)
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

struct ServiceFamilyRow: View {
    @ObservedObject var monitor: Monitor
    let title: String
    let service: ServiceStatus
    let queue: ServiceStatus?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                StatusDot(healthy: service.healthy, reason: service.detail)
                    .frame(width: 8, height: 20)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            ServiceSwitch(monitor: monitor, status: service)
                .frame(width: 44)
            Group {
                if let queue {
                    HStack(spacing: 4) {
                        StatusDot(healthy: queue.healthy, reason: queue.detail)
                            .frame(width: 8, height: 20)
                        ServiceSwitch(monitor: monitor, status: queue)
                    }
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }.frame(width: 58)
            if monitor.pending[service.id] != nil || (queue.map { monitor.pending[$0.id] != nil } ?? false) {
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
    private var modelPicker: some View {
        Picker("Model", selection: Binding(get: { value.model ?? "" }, set: { value.model = $0 })) {
            if value.id == "image" {
                Text("Z-Image Turbo").tag("z-image-turbo")
                Text("Chroma1-HD").tag("chroma1-hd")
                Text("Chroma1-Flash").tag("chroma1-flash")
            } else {
                Text("Higgs TTS 3").tag("higgs")
                Text("VoxCPM2").tag("voxcpm2")
                Text("Qwen3-TTS").tag("qwen3")
                Text("Chatterbox Original").tag("chatterbox")
                Text("IndexTTS").tag("indextts")
                Text("MOSS").tag("moss")
                Text("Fish").tag("fish")
            }
        }.labelsHidden().font(.system(size: 12)).controlSize(.small)
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
                        if generator { formRow("Model") { modelPicker } }
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
            }.scrollIndicators(.hidden)
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
    var body: some View {
        Group {
            if let id = monitor.selectedID, let value = monitor.settings.first(where: { $0.id == id }) {
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
                        if let error = monitor.error { ErrorNotice(text: error) { monitor.error = nil } }
                    }
                }.padding(12)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor()
    private var timer: Timer?
    private var pollingInterval: TimeInterval?
    private var focusObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.daemonmonitor")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Daemon Monitor")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 17, height: 16)
            button.target = self
            button.action = #selector(clickStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Daemon Monitor"
            button.setAccessibilityLabel("Daemon Monitor")
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor))
        resize()
        monitor.layoutChanged = { [weak self] in DispatchQueue.main.async { self?.resize() } }
        monitor.statusChanged = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = "Daemon Monitor — \(self.monitor.statuses.filter(\.healthy).count) of 5 healthy"
        }
        monitor.loadSettings()
        monitor.refresh()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self,
                      let window = notification.object as? NSWindow,
                      window === self.popover.contentViewController?.view.window else { return }
                self.updatePollingSchedule()
            })
        }
        updatePollingSchedule()
    }
    private func updatePollingSchedule() {
        let focused = popover.isShown && NSApp.isActive && popover.contentViewController?.view.window?.isKeyWindow == true
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
    private func resize() {
        if let id = monitor.selectedID {
            let base: CGFloat = id == "image" ? 304 : id == "voice" ? 274 : id == "bridge" ? 218 : 188
            let extra: CGFloat = monitor.settingsExpanded ? (id == "bridge" ? 188 : 160) : 0
            popover.contentSize = NSSize(width: 360, height: base + extra + (monitor.error == nil ? 0 : 76))
        } else {
            popover.contentSize = NSSize(width: 320, height: monitor.error == nil ? 160 : 244)
        }
    }
    @objc private func clickStatusItem(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = statusItem.button else { return }
        monitor.refresh()
        monitor.loadSettings()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        updatePollingSchedule()
    }
    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh status", action: #selector(refreshStatus), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open logs", action: #selector(openLogs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Daemon Monitor", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc private func refreshStatus() { monitor.refresh() }
    @objc private func openLogs() { monitor.openLogs() }
    @objc private func quit() { NSApp.terminate(nil) }
    func popoverDidShow(_ notification: Notification) { updatePollingSchedule() }
    func popoverDidClose(_ notification: Notification) { updatePollingSchedule() }
    func applicationDidBecomeActive(_ notification: Notification) { updatePollingSchedule() }
    func applicationDidResignActive(_ notification: Notification) { updatePollingSchedule() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
