import Foundation
import AppKit

final class CameraPlugin {
    struct Action { var settings: [String: Any]; var dial: Bool }
    private struct ControlRequest {
        let context: String
        let cameras: [CameraConfig]
        let parameter: String?
        let command: String?
        var ticks: Int
        let reset: Bool
        let fine: Bool
        let generation: UInt64
    }
    private struct CameraJob {
        let token = UUID()
        var request: ControlRequest
        // A nil source identifies the leader. Followers receive the immutable
        // value resolved by that leader, then translate their own enum table.
        var source: CameraSnapshot?
        var wire: Double?
        var resolvedCommand: String?
    }
    private struct ExpectedValue {
        let value: Double
        let context: String
        let token: UUID
        var accepted = false
        var attempts = 0
    }
    private struct CommandCheck {
        let context: String
        let token: UUID
        var accepted = false
    }
    private struct ReadTicket {
        let token: UUID
        let generation: UInt64
        let revision: UInt64
        let routine: Bool
    }
    private struct ActionFailure { let message: String; let expires: Date }
    private var socket: URLSessionWebSocketTask!
    private var actions: [String: Action] = [:]
    private var snapshots: [String: CameraSnapshot] = [:]
    private var snapshotTimes: [String: Date] = [:]
    private var failures: [String: String] = [:]
    private var readClients: [String: CameraClient] = [:]
    private var controlClients: [String: CameraClient] = [:]
    private var controlQueues: [String: DispatchQueue] = [:]
    private var cameraJobs: [String: [CameraJob]] = [:]
    private var runningJobs: [String: CameraJob] = [:]
    private var expected: [String: [String: ExpectedValue]] = [:]
    private var commandChecks: [String: CommandCheck] = [:]
    private var verificationDue: [String: Date] = [:]
    private var lastInteraction: [String: Date] = [:]
    // Only an acknowledged POST extends the burst cache window. A newly
    // enqueued turn must never make an old desired value appear recent.
    private var lastAcceptedAt: [String: Date] = [:]
    private var readTickets: [String: ReadTicket] = [:]
    private var cameraRevisions: [String: UInt64] = [:]
    private var configGeneration: UInt64 = 0
    private var pressedRotations: Set<String> = []
    private var actionFailures: [String: ActionFailure] = [:]
    private let state = DispatchQueue(label: "camera.plugin.state")
    private var timer: DispatchSourceTimer?
    private var config = ConfigStore.empty()
    private var lastConfig: Data?
    private var lastFeedback: [String: Data] = [:]
    private var stopping = false
    private let labels = ["wb":"WHITE BALANCE", "tint":"CC TINT", "shutter":"SHUTTER", "ei":"EXPOSURE INDEX", "nd":"ND FILTER", "fps":"SENSOR FPS", "playback":"PLAYBACK"]

    func start(arguments: [String]) {
        func arg(_ name: String) -> String { guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i+1) else { return "" }; return arguments[i+1] }
        guard let port = Int(arg("-port")), (1...65535).contains(port), let url = URL(string: "ws://127.0.0.1:\(port)") else { exit(2) }
        socket = URLSession(configuration: .default).webSocketTask(with: url)
        socket.resume()
        send(["event":arg("-registerEvent"),"uuid":arg("-pluginUUID")])
        log("Registered native camera plugin")
        receive()
        state.async { self.reloadConfig(); self.poll() }
        let timer = DispatchSource.makeTimerSource(queue: state)
        timer.schedule(deadline: .now()+0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.reloadConfig(); self?.poll(); self?.renderAll() }
        timer.resume(); self.timer = timer
    }
    private func log(_ message: String) {
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        let url = ConfigStore.directory.appendingPathComponent("plugin.log")
        if let data = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n".data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
            else if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() }
        }
    }
    private func receive() {
        socket.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                let data: Data
                switch message { case .data(let d): data=d; case .string(let s): data=Data(s.utf8); @unknown default: data=Data() }
                if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] { self.state.async { self.handle(object) } }
                self.receive()
            case .failure(let error):
                self.log("Stream Deck connection closed: \(error.localizedDescription)")
                self.state.async {
                    self.stopping = true; self.timer?.cancel(); self.configGeneration &+= 1
                    self.cameraJobs.removeAll()
                    for client in self.readClients.values { client.cancelPendingReads() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { exit(0) }
            }
        }
    }
    private func send(_ object: [String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
    private func reloadConfig() {
        guard let data = try? Data(contentsOf: ConfigStore.url), data != lastConfig, let next = try? JSONDecoder().decode(BuilderConfig.self, from: data) else { return }
        var previousControls = config
        previousControls.feedbackMode = next.feedbackMode
        let controlsChanged = previousControls != next
        let modeChanged = config.feedbackMode != next.feedbackMode
        config = next; lastConfig = data; lastFeedback.removeAll()
        if controlsChanged {
            configGeneration &+= 1
            for client in readClients.values { client.cancelPendingReads() }
            cameraJobs.removeAll(); expected.removeAll(); commandChecks.removeAll(); verificationDue.removeAll()
            snapshots.removeAll(); snapshotTimes.removeAll(); failures.removeAll(); actionFailures.removeAll()
            readClients.removeAll(); controlClients.removeAll(); controlQueues.removeAll(); readTickets.removeAll()
            lastInteraction.removeAll(); lastAcceptedAt.removeAll()
            // Existing workers retain their own clients. Generation checks
            // prevent those old-address responses from changing new state.
            runningJobs.removeAll()
        } else if modeChanged && next.feedbackMode == .off {
            for (id, ticket) in readTickets where ticket.routine { invalidateRead(id) }
        }
        renderAll()
    }
    private func targets(for action: Action) -> [CameraConfig] {
        let id = action.settings["cameraID"] as? String ?? config.selectedCameraID
        if id == "gang" || config.gangEnabled { return config.cameras.filter { config.gangIDs.contains($0.id) } }
        return config.cameras.filter { $0.id == id }
    }
    private func current(_ request: ControlRequest) -> Bool {
        !stopping && configGeneration == request.generation && actions[request.context] != nil
    }
    private func invalidateRead(_ id: String) {
        cameraRevisions[id, default: 0] &+= 1
        readClients[id]?.cancelPendingReads()
        // Keep the ticket until its cancelled callback has finished, so a
        // mutable read client never has two reads executing concurrently.
    }
    private func poll() {
        guard !stopping else { return }
        let now = Date()
        let visibleIDs = Set(actions.values.flatMap { targets(for: $0).map(\.id) })
        for camera in config.cameras {
            let id = camera.id
            guard readTickets[id] == nil, runningJobs[id] == nil, cameraJobs[id, default: []].isEmpty,
                  now.timeIntervalSince(lastInteraction[id] ?? .distantPast) >= 0.25 else { continue }
            let needsVerification = expected[id]?.values.contains(where: { $0.accepted }) == true || commandChecks[id]?.accepted == true
            if needsVerification {
                if now >= (verificationDue[id] ?? .distantPast) { beginRead(camera, routine: false) }
            } else if visibleIDs.contains(id), let interval = config.feedbackMode.pollInterval,
                      now.timeIntervalSince(snapshotTimes[id] ?? .distantPast) >= interval {
                beginRead(camera, routine: true)
            }
        }
    }
    private func beginRead(_ camera: CameraConfig, routine: Bool) {
        let client: CameraClient
        if let cached = readClients[camera.id] { client = cached }
        else { client = CameraClient(address: camera.address); readClients[camera.id] = client }
        let ticket = ReadTicket(token: UUID(), generation: configGeneration, revision: cameraRevisions[camera.id, default: 0], routine: routine)
        readTickets[camera.id] = ticket
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try client.read() }
            self.state.async {
                guard self.readTickets[camera.id]?.token == ticket.token else { return }
                self.readTickets.removeValue(forKey: camera.id)
                guard !self.stopping, self.configGeneration == ticket.generation,
                      self.cameraRevisions[camera.id, default: 0] == ticket.revision else { return }
                switch result {
                case .success(let snapshot):
                    self.snapshots[camera.id] = snapshot; self.snapshotTimes[camera.id] = Date()
                    self.failures.removeValue(forKey: camera.id)
                    if !ticket.routine { self.verify(camera, snapshot: snapshot) }
                case .failure(let error):
                    self.snapshots.removeValue(forKey: camera.id); self.snapshotTimes.removeValue(forKey: camera.id)
                    self.failures[camera.id] = error.localizedDescription
                    if !ticket.routine {
                        let contexts = Set((self.expected[camera.id] ?? [:]).values.map(\.context) + [self.commandChecks[camera.id]?.context].compactMap { $0 })
                        self.expected.removeValue(forKey: camera.id); self.commandChecks.removeValue(forKey: camera.id)
                        self.lastAcceptedAt.removeValue(forKey: camera.id)
                        for context in contexts { self.alert(context, "\(camera.name): \(error.localizedDescription)") }
                    }
                    // Failed routine reads are paced too, including OFFLINE.
                    self.snapshotTimes[camera.id] = Date()
                }
                self.renderAll()
            }
        }
    }
    private func verify(_ camera: CameraConfig, snapshot: CameraSnapshot) {
        let id = camera.id
        var values = expected[id] ?? [:]
        for (key, var expectation) in values where expectation.accepted {
            if let actual = snapshot.number(key), abs(actual-expectation.value) <= 0.001 {
                values.removeValue(forKey: key)
            } else {
                expectation.attempts += 1
                if expectation.attempts >= 3 {
                    values.removeValue(forKey: key)
                    alert(expectation.context, "\(camera.name): \(CameraError.verification(key).localizedDescription)")
                } else { values[key] = expectation }
            }
        }
        if values.isEmpty { expected.removeValue(forKey: id) } else { expected[id] = values }
        // A command has no single numeric target. A new authoritative snapshot
        // refreshes its display; transport acceptance never supplies a value.
        if commandChecks[id]?.accepted == true { commandChecks.removeValue(forKey: id) }
        verificationDue[id] = Date().addingTimeInterval(0.1)
    }
    private func handle(_ event: [String:Any]) {
        reloadConfig()
        let name = event["event"] as? String ?? ""
        let context = event["context"] as? String ?? ""
        let payload = event["payload"] as? [String:Any] ?? [:]
        switch name {
        case "willAppear", "didReceiveSettings":
            let settings = payload["settings"] as? [String:Any] ?? [:]
            let isDial = (payload["controller"] as? String == "Encoder") || (event["action"] as? String)?.hasSuffix(".dial") == true
            actions[context] = Action(settings: settings, dial: isDial)
            lastFeedback.removeValue(forKey: context)
            if isDial {
                let parameter = settings["parameter"] as? String ?? "wb"
                send(["event":"setImage","context":context,"payload":["image":"Images/\(parameter == "playback" ? "playPause" : parameter).png","target":0]])
                send(["event":"setFeedbackLayout","context":context,"payload":["layout":"layouts/camera.json"]])
                let resets = ["wb":"Reset white balance to 5600K","tint":"Reset CC tint to zero","shutter":"Reset shutter to 180°","ei":"Reset exposure index to 800","nd":"Reset ND filter to clear","fps":"Reset sensor rate to 24 fps","playback":"Play or pause"]
                let description = resets[parameter] ?? "Reset setting"
                send(["event":"setTriggerDescription","context":context,"payload":["rotate":"Adjust \(labels[parameter]?.lowercased() ?? parameter)","push":description,"touch":description]])
            } else {
                let command = settings["command"] as? String ?? "settings"
                let icons = ["settings":"settings","gang":"gang","playback":"playback","live":"live","previousClip":"previousClip","nextClip":"nextClip"]
                if let icon = icons[command] { send(["event":"setImage","context":context,"payload":["image":"Images/\(icon).png","target":0]]) }
            }
            renderAll(); poll()
        case "willDisappear":
            actions.removeValue(forKey: context); lastFeedback.removeValue(forKey: context)
            actionFailures.removeValue(forKey: context); pressedRotations.remove(context)
            for id in Array(cameraJobs.keys) { cameraJobs[id]?.removeAll { $0.request.context == context } }
        case "dialDown": pressedRotations.remove(context)
        case "dialRotate":
            let ticks = (payload["ticks"] as? NSNumber)?.intValue ?? 0
            guard ticks != 0 else { return }
            let pressed = payload["pressed"] as? Bool ?? false
            if pressed { pressedRotations.insert(context) }
            operate(context, ticks: ticks, reset: false, fine: pressed)
        case "dialUp":
            if pressedRotations.remove(context) == nil { operate(context, ticks: 0, reset: true, fine: false) }
        case "touchTap": operate(context, ticks: 0, reset: true, fine: false)
        case "keyDown": button(context)
        case "sendToPlugin":
            if payload["command"] as? String == "settings" { openBuilder(gang: false) }
            if payload["command"] as? String == "gang" { openBuilder(gang: true) }
            send(["event":"sendToPropertyInspector","context":context,"payload":["cameras":config.cameras.map { ["id":$0.id,"name":$0.name,"address":$0.address] },"gangEnabled":config.gangEnabled]])
        default: break
        }
    }
    private func operate(_ context: String, ticks: Int, reset: Bool, fine: Bool) {
        guard let action = actions[context] else { return }
        let cameras = targets(for: action)
        guard let leader = cameras.first else { openBuilder(gang: true); return }
        let request = ControlRequest(context: context, cameras: cameras, parameter: action.settings["parameter"] as? String ?? "wb", command: nil,
                                     ticks: max(-1000, min(1000, ticks)), reset: reset, fine: fine, generation: configGeneration)
        enqueue(CameraJob(request: request), camera: leader)
        renderAll()
    }
    private func button(_ context: String) {
        guard let action = actions[context] else { return }
        let command = action.settings["command"] as? String ?? "settings"
        if command == "settings" { openBuilder(gang: false); return }
        if command == "gang" { openBuilder(gang: true); return }
        let cameras = targets(for: action)
        guard let leader = cameras.first else { openBuilder(gang: true); return }
        let request = ControlRequest(context: context, cameras: cameras, parameter: nil, command: command, ticks: 0, reset: false, fine: false, generation: configGeneration)
        enqueue(CameraJob(request: request), camera: leader)
        renderAll()
    }
    private func canCoalesce(_ first: CameraJob, _ second: CameraJob) -> Bool {
        let a = first.request, b = second.request
        return a.context == b.context && a.parameter != nil && a.parameter == b.parameter && a.command == nil && b.command == nil &&
            !a.reset && !b.reset && a.fine == b.fine && a.generation == b.generation && ((first.source == nil) == (second.source == nil))
    }
    private func enqueue(_ job: CameraJob, camera: CameraConfig) {
        guard current(job.request) else { return }
        let id = camera.id
        lastInteraction[id] = Date(); invalidateRead(id)
        var queue = cameraJobs[id] ?? []
        if var tail = queue.last, canCoalesce(tail, job) {
            if job.source == nil { tail.request.ticks = max(-1000, min(1000, tail.request.ticks+job.request.ticks)) }
            else { tail = job }
            queue[queue.count-1] = tail
        } else { queue.append(job) }
        cameraJobs[id] = queue
        startNext(camera)
    }
    private func startNext(_ camera: CameraConfig) {
        let id = camera.id
        guard !stopping, runningJobs[id] == nil else { return }
        while var queue = cameraJobs[id], !queue.isEmpty {
            let job = queue.removeFirst(); cameraJobs[id] = queue
            guard current(job.request) else { continue }
            if job.request.parameter != nil && !job.request.reset && job.request.ticks == 0 { continue }
            invalidateRead(id); runningJobs[id] = job
            let client: CameraClient
            if let cached = controlClients[id] { client = cached }
            else { client = CameraClient(address: camera.address); controlClients[id] = client }
            let worker: DispatchQueue
            if let cached = controlQueues[id] { worker = cached }
            else { worker = DispatchQueue(label: "camera.plugin.control.\(id)", qos: .userInitiated); controlQueues[id] = worker }
            let now = Date()
            let pendingAccepted = (expected[id] ?? [:]).filter { $0.value.accepted }
            let burst = !pendingAccepted.isEmpty && now.timeIntervalSince(lastAcceptedAt[id] ?? .distantPast) < 0.75
            let snapshotAge = now.timeIntervalSince(snapshotTimes[id] ?? .distantPast)
            let fresh = snapshotAge <= 2
            // An old, still-unverified intent must rebase on a new GET even
            // if the pre-command snapshot itself is inside the normal TTL.
            // Continuous turns may extend the fast burst briefly, but firmware
            // capability / readonly metadata is authoritatively rebased at
            // least every five seconds before another setting is submitted.
            let reusable = pendingAccepted.isEmpty ? fresh : burst && snapshotAge <= 5
            let cached = reusable ? snapshots[id] : nil
            let desired = cached != nil && burst ? pendingAccepted.mapValues { $0.value } : [:]
            worker.async { self.execute(job, camera: camera, client: client, cached: cached, accepted: desired) }
            return
        }
    }
    private func execute(_ job: CameraJob, camera: CameraConfig, client: CameraClient, cached: CameraSnapshot?, accepted: [String: Double]) {
        let request = job.request
        let token = job.token
        var completionScheduled = false
        defer {
            if !completionScheduled {
                state.async {
                    guard self.configGeneration == request.generation, self.runningJobs[camera.id]?.token == token else { return }
                    self.expected[camera.id] = self.expected[camera.id]?.filter { $0.value.token != token }
                    if self.expected[camera.id]?.isEmpty == true { self.expected.removeValue(forKey: camera.id) }
                    if self.commandChecks[camera.id]?.token == token { self.commandChecks.removeValue(forKey: camera.id) }
                    self.runningJobs.removeValue(forKey: camera.id)
                    self.startNext(camera); self.renderAll()
                }
            }
        }
        do {
            guard state.sync(execute: { current(request) }) else { return }
            let actual: CameraSnapshot
            if let cached = cached { actual = cached }
            else {
                actual = try client.read()
                guard state.sync(execute: { () -> Bool in
                    guard current(request) else { return false }
                    snapshots[camera.id] = actual; snapshotTimes[camera.id] = Date(); failures.removeValue(forKey: camera.id)
                    return true
                }) else { return }
            }
            // Accepted intent is used for relative turns only while the burst
            // is current. It never enters the authoritative feedback cache.
            let usableAccepted = cached == nil ? [:] : accepted
            // Play/stop can remain available while the speed variable is read
            // only. Track that command's desired speed without pretending a
            // writable speed setting was sent to the camera.
            let basis = try actual.applying(usableAccepted.filter { actual.canWrite($0.key) })
            var source = job.source ?? basis
            var wire = job.wire
            var resolvedCommand = job.resolvedCommand
            if job.source == nil {
                if let parameter = request.parameter {
                    if request.reset && parameter == "playback" {
                        let key = basis.key(for: parameter)
                        guard let current = usableAccepted[key] ?? basis.number(key), let speed = basis.enumCatalog.choices[key]?.first(where: { $0.wireValue == current })?.numericValue else { throw CameraError.unavailable("Playback play/pause") }
                        resolvedCommand = speed == 0 ? "PlayBackGo" : "PlayBackStop"
                    } else if request.reset {
                        guard let reset = basis.resetValue(parameter) else { throw CameraError.unavailable("Reset for \(parameter)") }
                        wire = reset
                    } else { wire = try basis.steppedValue(parameter: parameter, ticks: request.ticks, fine: request.fine) }
                } else if let command = request.command {
                    let commands = ["playback":"PlaybackEnter","live":"PlaybackExit","previousClip":"PlaybackSkipRev","nextClip":"PlaybackSkipFwd"]
                    guard let name = commands[command] else { throw BuilderError.message("Unknown camera button.") }
                    resolvedCommand = name
                }
                source = basis
            }
            let immutableSource = source, immutableWire = wire, immutableCommand = resolvedCommand
            let allowed = state.sync { () -> Bool in
                guard current(request) else { return false }
                // Start followers before this POST; an unavailable follower
                // can never hold the leader's next command or verification.
                if job.source == nil {
                    for follower in request.cameras.dropFirst() {
                        enqueue(CameraJob(request: request, source: immutableSource, wire: immutableWire, resolvedCommand: immutableCommand), camera: follower)
                    }
                }
                return true
            }
            guard allowed else { return }
            var payload: [String: Any] = [:]
            if let parameter = request.parameter, let wire = wire {
                let destination = try actual.convertedWireValue(wire, parameter: parameter, from: source)
                payload = try actual.validatedValues([actual.key(for: parameter): destination])
            }
            let capturedPayload = payload
            var verificationValues = payload
            if resolvedCommand == "PlayBackGo" || resolvedCommand == "PlayBackStop" {
                let key = actual.key(for: "playback")
                let speed: Double = resolvedCommand == "PlayBackGo" ? 1 : 0
                if let choice = actual.enumCatalog.choices[key]?.first(where: { $0.numericValue == speed }) {
                    verificationValues[key] = choice.wireValue
                }
            }
            let capturedVerification = verificationValues
            guard state.sync(execute: { () -> Bool in
                guard current(request) else { return false }
                for (key, value) in capturedVerification { if let number = value as? NSNumber { expected[camera.id, default: [:]][key] = ExpectedValue(value: number.doubleValue, context: request.context, token: token) } }
                if immutableCommand != nil { commandChecks[camera.id] = CommandCheck(context: request.context, token: token) }
                renderAll()
                return true
            }) else { return }
            if let command = resolvedCommand { try client.submitCommand(command, using: actual) }
            else { _ = try client.submit(capturedPayload, using: actual) }
            state.async { self.finished(job, camera: camera, token: token, error: nil) }
            completionScheduled = true
        } catch {
            state.async { self.finished(job, camera: camera, token: token, error: error) }
            completionScheduled = true
        }
    }
    private func finished(_ job: CameraJob, camera: CameraConfig, token: UUID, error: Error?) {
        guard configGeneration == job.request.generation, runningJobs[camera.id]?.token == job.token else { return }
        let id = camera.id
        runningJobs.removeValue(forKey: id)
        if let error = error {
            expected[id] = expected[id]?.filter { $0.value.token != token }
            if expected[id]?.isEmpty == true { expected.removeValue(forKey: id) }
            if commandChecks[id]?.token == token { commandChecks.removeValue(forKey: id) }
            snapshotTimes.removeValue(forKey: id); lastAcceptedAt.removeValue(forKey: id)
            alert(job.request.context, "\(camera.name): \(error.localizedDescription)")
        } else {
            for key in Array((expected[id] ?? [:]).keys) where expected[id]?[key]?.token == token { expected[id]?[key]?.accepted = true }
            if commandChecks[id]?.token == token { commandChecks[id]?.accepted = true }
            lastAcceptedAt[id] = Date(); verificationDue[id] = Date().addingTimeInterval(0.15)
        }
        // POST acknowledgement releases this camera immediately. Neither
        // another camera nor any low-priority readback occupies its queue.
        startNext(camera)
        renderAll()
    }
    private func alert(_ context: String, _ message: String) {
        log("Control failed: \(message)")
        send(["event":"showAlert","context":context])
        actionFailures[context] = ActionFailure(message: message, expires: Date().addingTimeInterval(3))
        lastFeedback.removeValue(forKey: context)
        if let action = actions[context] { render(context, action) }
    }
    private func openBuilder(gang: Bool) {
        DispatchQueue.main.async { NSWorkspace.shared.open(URL(string:"cameraprofilebuilder://\(gang ? "gang" : "settings")")!) }
    }
    private func renderAll() { for (context, action) in actions { render(context, action) } }
    private func pending(_ camera: CameraConfig, parameter: String) -> Bool {
        let id = camera.id, key = snapshots[id]?.key(for: parameter) ?? CameraSnapshot.parameterKeys[parameter] ?? parameter
        if expected[id]?[key] != nil || (parameter == "playback" && commandChecks[id] != nil) { return true }
        func matches(_ job: CameraJob) -> Bool { job.request.parameter == parameter || (parameter == "playback" && job.request.command != nil) }
        return runningJobs[id].map(matches) == true || cameraJobs[id, default: []].contains(where: matches)
    }
    private func render(_ context: String, _ action: Action) {
        let cameras = targets(for: action)
        let gang = (action.settings["cameraID"] as? String == "gang") || config.gangEnabled
        let target = gang ? "GANG · \(cameras.count) CAM" : (cameras.first?.name ?? "NO CAMERA")
        if let failure = actionFailures[context], failure.expires <= Date() { actionFailures.removeValue(forKey: context) }
        let activeFailure = actionFailures[context]
        if !action.dial {
            let command = action.settings["command"] as? String ?? "settings"
            let titles = ["settings":"SETTINGS", "playback":"PLAYBACK", "live":"LIVE VIEW", "previousClip":"PREV CLIP", "nextClip":"NEXT CLIP"]
            let title: String
            if activeFailure != nil { title = "FAILED" }
            else if command == "gang" { title = config.gangEnabled ? "GANG ON\n\(cameras.count) CAM" : "GANG\nSELECT" }
            else { title = titles[command] ?? command.uppercased() }
            let payload: [String: Any] = ["title": title, "target": 0]
            if let encoded = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), encoded != lastFeedback[context] {
                lastFeedback[context] = encoded; send(["event":"setTitle", "context":context, "payload":payload])
            }
            return
        }
        let parameter = action.settings["parameter"] as? String ?? "wb"
        let descriptions = cameras.compactMap { snapshots[$0.id]?.description(for: parameter) }
        let missing = cameras.filter { snapshots[$0.id] == nil }
        let failed = missing.filter { failures[$0.id] != nil }
        let waiting = cameras.contains { pending($0, parameter: parameter) }
        let value: String
        if activeFailure != nil { value = "FAILED" }
        else if cameras.isEmpty { value = "SELECT CAM" }
        else if waiting { value = "PENDING" }
        else if !failed.isEmpty { value = cameras.count == 1 ? "OFFLINE" : "\(failed.count) OFFLINE" }
        else if !missing.isEmpty { value = config.feedbackMode == .off ? "FEEDBACK OFF" : "CONNECTING" }
        else if Set(descriptions).count > 1 { value = "MIXED" }
        else { value = descriptions.first ?? "UNAVAILABLE" }
        let hint: String
        let oldestRead = cameras.compactMap { snapshotTimes[$0.id] }.min()
        let cachedAge = oldestRead.map { max(0, Int(Date().timeIntervalSince($0))) }
        if let failure = activeFailure { hint = String(failure.message.prefix(42)) }
        else if waiting { hint = "Last confirmed: \(Set(descriptions).count > 1 ? "MIXED" : descriptions.first ?? "waiting")" }
        else if value == "MIXED" { hint = "Turn to match first camera" }
        else if !failed.isEmpty { hint = "Check network / camera IP" }
        else if let age = cachedAge, config.feedbackMode != .live || age > 2 { hint = "Cached · \(config.feedbackMode.title) · \(age)s since read" }
        else if config.feedbackMode == .off { hint = "Feedback off · Input still confirms" }
        else if parameter == "playback" { hint = "Turn: speed · Press: play/pause" }
        else { hint = "Turn: adjust · Press: reset" }
        let payload: [String:Any] = ["title":labels[parameter] ?? parameter.uppercased(), "value":value, "target":target, "hint":hint,"icon":"Images/\(parameter).png"]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), encoded != lastFeedback[context] else { return }
        lastFeedback[context] = encoded; send(["event":"setFeedback","context":context,"payload":payload])
        let diagnostic = ["updated":ISO8601DateFormatter().string(from: Date()),"parameter":parameter,"value":value,"target":target]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options:.prettyPrinted) {
            try? data.write(to: ConfigStore.directory.appendingPathComponent("feedback-\(parameter).json"), options:.atomic)
        }
    }
}
