import Foundation

// Exercise the real Monitor with delayed helper replies; no daemons are started or stopped.
@main
enum MonitorTests {
    final class FakeHelper {
        struct Request {
            let arguments: [String]
            let completion: Helper.Completion
        }
        var requests: [Request] = []
        func call(_ arguments: [String], _ input: Data?, _ completion: @escaping Helper.Completion) {
            requests.append(Request(arguments: arguments, completion: completion))
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
        precondition(monitor.error != nil)
    }

    static func main() {
        for on in [false, true] {
            for polling in [false, true] { transition(on: on, polling: polling) }
        }
        failedStop()
        failedRefresh()
        print("Passed 6 monitor checks: on/off transitions, overlapping polls, failed stop, and failed refresh.")
    }
}
