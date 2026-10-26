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
    @Published var selectedID: String? { didSet { layoutChanged?() } }
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
            let origin = NSPoint(x: min(max(anchor.midX - size.width / 2, screen.minX + 6), screen.maxX - size.width - 6),
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

struct ServiceRow: View {
    @ObservedObject var monitor: Monitor
    let status: ServiceStatus
    var body: some View {
        HStack(spacing: 11) {
            StatusDot(healthy: status.healthy, reason: status.detail)
                .frame(width: 12, height: 24)
            Text(status.name).font(.system(size: 13, weight: .medium))
                .help(status.detail + " · localhost:" + String(status.port))
            Spacer(minLength: 8)
            if monitor.pending[status.id] != nil {
                ProgressView().controlSize(.mini).frame(width: 14)
            }
            Toggle(status.name, isOn: Binding(
                get: { monitor.pending[status.id] ?? status.running },
                set: { monitor.toggle(status, on: $0) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled(monitor.isBusy(status.id))
            .accessibilityLabel(status.name)
            Button {
                monitor.error = nil
                monitor.selectedID = status.id
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 20, height: 28)
            }
            .buttonStyle(.plain)
            .help("Startup settings for " + status.name)
            .accessibilityLabel("Startup settings for " + status.name)
        }
        .frame(height: 39)
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
    init(monitor: Monitor, value: ServiceSettings) {
        self.monitor = monitor
        _value = State(initialValue: value)
        _port = State(initialValue: String(value.port))
        _queuePort = State(initialValue: String(monitor.settings.first(where: { $0.id == value.id + "-queue" })?.port ?? 0))
    }
    func pathField(_ title: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField(title, text: binding).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                .help(binding.wrappedValue)
        }
    }
    func portField(_ title: String, _ binding: Binding<String>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, text: binding).textFieldStyle(.roundedBorder).frame(width: 80) }
            .font(.system(size: 12))
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Button { monitor.error = nil; monitor.selectedID = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).accessibilityLabel("Back to services")
                Text(value.name).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Saved settings apply the next time this service starts.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    pathField(value.id == "bridge" ? "State folder" : "Project folder", $value.root)
                    if value.id == "bridge" {
                        pathField("Executable", Binding(get: { value.binary ?? "" }, set: { value.binary = $0 }))
                    }
                    portField("Port", $port)
                    if generator {
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
                        }.font(.system(size: 12))
                        portField("Queue port", $queuePort)
                        Toggle("Prompt expansion", isOn: Binding(get: { value.llm ?? true }, set: { value.llm = $0 }))
                            .toggleStyle(.switch).controlSize(.small)
                        if value.id == "image" {
                            Toggle("LoRAs", isOn: Binding(get: { value.loras ?? true }, set: { value.loras = $0 }))
                                .toggleStyle(.switch).controlSize(.small)
                        }
                        Text("Starting a generator also starts its queue if needed. Model assets must already be installed.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if value.id == "bridge" {
                        Toggle("File-only logging", isOn: Binding(get: { value.log_file_only ?? true }, set: { value.log_file_only = $0 }))
                            .toggleStyle(.switch).controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Environment overrides").font(.system(size: 12, weight: .medium))
                        Text("Optional KEY=value entries, one per line. Values are literal.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        TextEditor(text: $value.environment).font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden).padding(5).frame(height: 84)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                            .accessibilityLabel("Environment overrides")
                    }
                    if let error = monitor.error { ErrorNotice(text: error) { monitor.error = nil } }
                }.padding(.trailing, 4)
            }
            HStack {
                Button("Open logs") { monitor.openLogs(value.id) }.controlSize(.small)
                Spacer()
                if monitor.saving { ProgressView().controlSize(.small) }
                Button("Save") { monitor.save(value, port: port, queuePort: generator ? queuePort : nil) }
                    .keyboardShortcut(.defaultAction).controlSize(.small)
                    .disabled(monitor.saving || monitor.isBusy(value.id))
            }
        }.padding(18)
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        Group {
            if let id = monitor.selectedID, let value = monitor.settings.first(where: { $0.id == id }) {
                SettingsView(monitor: monitor, value: value).id(id)
            } else {
                VStack(spacing: 4) {
                    if monitor.statuses.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ForEach(monitor.statuses) { status in ServiceRow(monitor: monitor, status: status) }
                        if let error = monitor.error { ErrorNotice(text: error) { monitor.error = nil }.padding(.top, 6) }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
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
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Daemon Monitor")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
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
        popover.contentSize = monitor.selectedID == nil
            ? NSSize(width: 344, height: monitor.error == nil ? 235 : 325)
            : NSSize(width: 430, height: 590)
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
