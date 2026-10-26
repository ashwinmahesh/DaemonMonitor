import AppKit

// Exercise the real Monitor with delayed helper replies; no daemons are started or stopped.
@main
enum MonitorTests {
    final class FakeHelper {
        struct Request {
            let arguments: [String]
            let input: Data?
            let completion: Helper.Completion
        }
        var requests: [Request] = []
        func call(_ arguments: [String], _ input: Data?, _ completion: @escaping Helper.Completion) {
            requests.append(Request(arguments: arguments, input: input, completion: completion))
        }
        func reply(_ arguments: [String], _ result: Result<Data, Error>) {
            guard let index = requests.firstIndex(where: { $0.arguments == arguments }) else {
                fatalError("Missing helper request: \(arguments)")
            }
            requests.remove(at: index).completion(result)
        }
    }

    static func status(_ running: Bool) -> ServiceStatus {
        ServiceStatus(id: "image", name: "Image gen service", running: running,
                      healthy: running, detail: running ? "Healthy" : "Not started.", port: 5732)
    }
    static func snapshot(_ running: Bool) -> Result<Data, Error> {
        .success(Data("""
        {"services":[{"id":"image","name":"Image gen service","running":\(running),"healthy":\(running),"detail":"status","port":5732}]}
        """.utf8))
    }
    static let success: Result<Data, Error> = .success(Data("{\"ok\":true}".utf8))
    static let failure: Result<Data, Error> = .failure(NSError(domain: "test", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The generator is busy."]))

    static func transition(on: Bool, polling: Bool) {
        let fake = FakeHelper()
        let monitor = Monitor(helper: fake.call)
        let original = status(!on)
        monitor.statuses = [original]
        if polling { monitor.refresh() }
        monitor.toggle(original, on: on)
        precondition(monitor.isOn("image") == on)
        fake.reply([on ? "start" : "stop", "image"], success)
        precondition(monitor.isOn("image") == on, "Action completion must not restore the old switch value")
        precondition(monitor.isBusy("image-queue"), "Keep the family disabled until status is reconciled")
        if polling {
            fake.reply(["status"], snapshot(!on))
            precondition(monitor.isOn("image") == on, "An older poll must not change the requested position")
            precondition(monitor.isBusy("image"), "An older poll must not complete the action")
        }
        precondition(fake.requests.map(\.arguments) == [["status"]])
        fake.reply(["status"], snapshot(on))
        precondition(!monitor.isBusy("image"))
        precondition(monitor.isOn(original.id) == on, "Read current status even when a view captured the old status value")
        precondition(fake.requests.isEmpty)
    }

    static func failedStop() {
        let fake = FakeHelper()
        let monitor = Monitor(helper: fake.call)
        monitor.statuses = [status(true)]
        monitor.toggle(status(true), on: false)
        fake.reply(["stop", "image"], failure)
        precondition(!monitor.isOn("image"), "Wait for actual status before rolling back a failed action")
        fake.reply(["status"], snapshot(true))
        precondition(monitor.isOn("image"))
        precondition(!monitor.isBusy("image"))
        precondition(monitor.error == "The generator is busy.")
    }

    static func failedRefresh() {
        let fake = FakeHelper()
        let monitor = Monitor(helper: fake.call)
        monitor.statuses = [status(false)]
        monitor.toggle(status(false), on: true)
        fake.reply(["start", "image"], success)
        fake.reply(["status"], failure)
        precondition(!monitor.isBusy("image"), "A failed status check must not leave controls disabled")
        precondition(monitor.statusError != nil)
    }

    static func history(_ id: String, _ range: String) -> Result<Data, Error> {
        .success(Data("""
        {"id":"\(id)","range":"\(range)","start":0,"end":300,"resolution":15,"recording_since":null,
         "points":[],"latest":null,"peaks":{"cpu":null,"memory":null,"gpu":null}}
        """.utf8))
    }

    static func staleHistory() {
        let fake = FakeHelper()
        let performance = PerformanceMonitor(helper: fake.call)
        performance.select("image")
        performance.range = .week
        fake.reply(["history", "image", "--range", "7d"], history("image", "7d"))
        fake.reply(["history", "image", "--range", "5m"], history("image", "5m"))
        precondition(performance.history?.range == "7d", "An older range response must not replace the selected history")
        performance.select("voice-queue")
        precondition(performance.history == nil)
        performance.select(nil)
        fake.reply(["history", "voice-queue", "--range", "7d"], history("voice-queue", "7d"))
        precondition(performance.history == nil, "Closed history must ignore late replies")
        fake.reply(["sample", "--interval", "60"], success)
        precondition(fake.requests.isEmpty, "Background sampling must not read hidden charts")
    }

    static func performanceSampling() {
        let fake = FakeHelper()
        let monitor = Monitor(helper: fake.call)
        monitor.performance.setSampling(focused: true)
        defer { monitor.performance.stop() }
        monitor.showPerformance("image-queue")
        precondition(monitor.performanceID == "image-queue")
        fake.reply(["history", "image-queue", "--range", "5m"], history("image-queue", "5m"))
        fake.reply(["sample", "--interval", "15"], success)
        precondition(fake.requests.map(\.arguments) == [["history", "image-queue", "--range", "5m"]])
        fake.reply(["history", "image-queue", "--range", "5m"], history("image-queue", "5m"))
        monitor.performance.sample()
        precondition(fake.requests.isEmpty, "Repeated clicks must not trigger duplicate collections")
        monitor.performanceID = nil
        precondition(HistoryRange.allCases.count == 7)
    }

    static func tooltipPorts() {
        for port in [8765, 55302, 55205, 65535] {
            let label = StatusDot.tooltipLabel(for: "Running on port \(port)")
            let natural = label.cell!.cellSize
            let visible = label.cell!.cellSize(forBounds: label.bounds)
            precondition(visible.width >= natural.width - 0.01, "The complete port must fit on one line")
            precondition(label.bounds.height >= natural.height, "The full line height must fit")
        }
        let stopped = StatusDot.tooltipLabel(for: "Not started.")
        precondition(stopped.bounds.width < 80, "Short tooltips must not have a fixed minimum width")
    }

    static func tooltipWrapping() {
        let label = StatusDot.tooltipLabel(for: String(repeating: "The service did not respond to its health check. ", count: 8))
        let required = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10000))
        precondition(label.bounds.width <= 260, "Long failure reasons must wrap within the popover")
        precondition(label.bounds.height >= required.height, "Wrapped failure reasons must remain fully visible")
        precondition(label.bounds.height > label.font!.boundingRectForFont.height)
    }

    static func statusRecovery() {
        for actionError in [nil, "The generator is busy."] as [String?] {
            let fake = FakeHelper()
            let monitor = Monitor(helper: fake.call)
            monitor.statuses = [status(true)]
            monitor.error = actionError
            monitor.refresh()
            fake.reply(["status"], failure)
            precondition(monitor.statusError != nil)
            precondition(monitor.isOn("image"), "A failed process check must preserve the last switch position")
            precondition(!monitor.statuses[0].healthy)
            monitor.refresh()
            fake.reply(["status"], snapshot(true))
            precondition(monitor.statusError == nil, "A successful poll must clear its earlier status error")
            precondition(monitor.error == actionError, "Polling must preserve unrelated action errors")
            precondition(monitor.statuses[0].healthy)
        }
    }

    static func browserEndpoints() {
        let monitor = Monitor(helper: FakeHelper().call)
        monitor.statuses = [
            ServiceStatus(id: "image", name: "Image", running: true, healthy: true, detail: "Healthy", port: 6732),
            ServiceStatus(id: "voice", name: "Voice", running: true, healthy: false, detail: "Loading", port: 6743),
            ServiceStatus(id: "image-queue", name: "Queue", running: true, healthy: true, detail: "Healthy", port: 65302)
        ]
        precondition(monitor.serviceUIURL("image")?.absoluteString == "http://127.0.0.1:6732/")
        precondition(monitor.serviceUIURL("voice")?.absoluteString == "http://127.0.0.1:6743/")
        precondition(monitor.serviceUIURL("image-queue") == nil)
        precondition(monitor.serviceUIURL("bridge") == nil)
        monitor.statuses[0].running = false
        precondition(monitor.serviceUIURL("image") == nil, "Stopped generators must not offer an unavailable UI")
    }

    static func runtimeModelStatus() {
        let fake = FakeHelper()
        let monitor = Monitor(helper: fake.call)
        for active in ["\"chroma1-hd\"", "\"flux2-klein-4b\"", "null"] {
            monitor.refresh()
            fake.reply(["status"], .success(Data("""
            {"services":[{"id":"image","name":"Image gen service","running":true,"healthy":true,
            "detail":"Healthy · ready","port":5732,"runtime_model_switching":true,
            "active_model":\(active),"busy":false}]}
            """.utf8)))
            let status = monitor.statuses[0]
            precondition(monitor.isOn("image") && status.healthy)
            precondition(status.activeModelSummary == "Active model: \(status.active_model ?? "None loaded")")
            precondition(fake.requests.isEmpty, "An active-model change must never issue a start/stop action")
        }
    }

    static func saveStartupWithoutModel() {
        let fake = FakeHelper()
        let monitor = Monitor(helper: fake.call)
        let settings = ServiceSettings(id: "image", name: "Image", port: 5732, root: "/test/image",
            binary: nil, llm: true, loras: true, log_file_only: nil, environment: "")
        monitor.save(settings, port: "5732", queuePort: "55302")
        let input = try! JSONSerialization.jsonObject(with: fake.requests[0].input!) as! [String: Any]
        precondition(input["model"] == nil, "Startup settings must not send a model override")
        fake.reply(["save"], success)
        fake.reply(["config"], .success(Data("{\"services\":[]}".utf8)))
        fake.reply(["status"], snapshot(false))
        precondition(fake.requests.isEmpty, "Saving startup settings must never restart or switch a generator")
    }

    static func main() {
        for on in [false, true] {
            for polling in [false, true] { transition(on: on, polling: polling) }
        }
        failedStop()
        failedRefresh()
        staleHistory()
        performanceSampling()
        tooltipPorts()
        tooltipWrapping()
        statusRecovery()
        browserEndpoints()
        runtimeModelStatus()
        saveStartupWithoutModel()
        print("Passed 14 monitor checks: toggles, polling races, failure recovery, history ranges, sampling, tooltip layout, browser endpoints, runtime models, and startup settings.")
    }
}
