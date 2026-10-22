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
    private struct ControlResult {
        var snapshots: [String: CameraSnapshot] = [:]
        var failures: [String: String] = [:]
    }
    private struct ActionFailure {
        let message: String
        let expires: Date
    }
    private var socket: URLSessionWebSocketTask!
    private var actions: [String: Action] = [:]
    private var snapshots: [String: CameraSnapshot] = [:]
    private var failures: [String: String] = [:]
    private var clients: [String: CameraClient] = [:]
    private var busy: Set<String> = []
    private var activeControlIDs: Set<String> = []
    private var cameraRevisions: [String: UInt64] = [:]
    private var configGeneration: UInt64 = 0
    private var pressedRotations: Set<String> = []
    private var pendingControls: [ControlRequest] = []
    private var controlRunning = false
    private var actionFailures: [String: ActionFailure] = [:]
    // Used only on `control`; never shared with the polling clients.
    private var controlClients: [String: CameraClient] = [:]
    private let state = DispatchQueue(label: "camera.plugin.state")
    private let control = DispatchQueue(label: "camera.plugin.control")
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
        timer.schedule(deadline: .now()+1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.reloadConfig(); self?.poll() }
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
                    self.stopping = true; self.timer?.cancel()
                    self.configGeneration &+= 1; self.pendingControls.removeAll()
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
        config = next; lastConfig = data; lastFeedback = [:]
        configGeneration &+= 1
        pendingControls.removeAll()
        actionFailures.removeAll()
        // No cached camera data survives an address edit.
        snapshots = [:]; failures = [:]; clients = [:]
        renderAll()
    }
    private func targets(for action: Action) -> [CameraConfig] {
        let id = action.settings["cameraID"] as? String ?? config.selectedCameraID
        if id == "gang" || config.gangEnabled { return config.cameras.filter { config.gangIDs.contains($0.id) } }
        return config.cameras.filter { $0.id == id }
    }
    private func client(_ camera: CameraConfig) -> CameraClient {
        if let client = clients[camera.id] { return client }
        let client = CameraClient(address: camera.address); clients[camera.id] = client; return client
    }
    private func poll() {
        guard !stopping else { return }
        let ids = Set(actions.values.flatMap { targets(for: $0).map(\.id) })
        for camera in config.cameras where ids.contains(camera.id) && !busy.contains(camera.id) && !activeControlIDs.contains(camera.id) {
            busy.insert(camera.id)
            let client = self.client(camera)
            let generation = configGeneration
            let revision = cameraRevisions[camera.id, default: 0]
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try client.read() }
                self.state.async {
                    self.busy.remove(camera.id)
                    // An old address response must not overwrite a newly saved camera.
                    guard self.configGeneration == generation,
                          self.cameraRevisions[camera.id, default: 0] == revision,
                          self.config.cameras.contains(where: { $0.id == camera.id && $0.address == camera.address }) else { return }
                    switch result { case .success(let s): self.snapshots[camera.id]=s; self.failures.removeValue(forKey: camera.id)
                    case .failure(let e): self.snapshots.removeValue(forKey: camera.id); self.failures[camera.id]=e.localizedDescription }
                    self.renderAll()
                }
            }
        }
    }
    private func handle(_ event: [String:Any]) {
        // A saved IP/gang edit takes effect on the next input, even between
        // periodic refreshes, and invalidates work queued for the old targets.
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
                let parameter=settings["parameter"] as? String ?? "wb"
                let image=parameter == "playback" ? "playPause" : parameter
                send(["event":"setImage","context":context,"payload":["image":"Images/\(image).png","target":0]])
                send(["event":"setFeedbackLayout","context":context,"payload":["layout":"layouts/camera.json"]])
                let resets=["wb":"Reset white balance to 5600K","tint":"Reset CC tint to zero","shutter":"Reset shutter to 180°","ei":"Reset exposure index to 800","nd":"Reset ND filter to clear","fps":"Reset sensor rate to 24 fps","playback":"Play or pause"]
                let description=resets[parameter] ?? "Reset setting"
                send(["event":"setTriggerDescription","context":context,"payload":["rotate":"Adjust \(labels[parameter]?.lowercased() ?? parameter)","push":description,"touch":description]])
            }
            renderAll(); poll()
        case "willDisappear":
            actions.removeValue(forKey: context); lastFeedback.removeValue(forKey: context)
            actionFailures.removeValue(forKey: context); pressedRotations.remove(context)
            pendingControls.removeAll { $0.context == context }
        case "dialDown": pressedRotations.remove(context)
        case "dialRotate":
            let ticks = (payload["ticks"] as? NSNumber)?.intValue ?? 0
            guard ticks != 0 else { return }
            let pressed = payload["pressed"] as? Bool ?? false
            if pressed { pressedRotations.insert(context) }
            operate(context, ticks: ticks, reset: false, fine: pressed)
        case "dialUp":
            // A pressed turn is a fine adjustment. Releasing it must not also
            // reset the value that the user just selected.
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
        let parameter = action.settings["parameter"] as? String ?? "wb"
        let cameras = targets(for: action)
        guard !cameras.isEmpty else { openBuilder(gang: true); return }
        let request = ControlRequest(context: context, cameras: cameras, parameter: parameter, command: nil,
                                     ticks: max(-1000, min(1000, ticks)), reset: reset, fine: fine,
                                     generation: configGeneration)
        if !reset, let index = pendingControls.lastIndex(where: { $0.context == context }),
           case let last = pendingControls[index],
           last.context == context, last.parameter == parameter, last.command == nil,
           !last.reset, last.fine == fine, last.generation == configGeneration {
            // One in-flight operation plus one accumulated turn replaces an
            // unbounded queue of HTTP read/write cycles while spinning a dial.
            pendingControls[index].ticks = max(-1000, min(1000, last.ticks + request.ticks))
        } else {
            pendingControls.append(request)
        }
        startNextControl()
    }
    private func button(_ context: String) {
        guard let action = actions[context] else { return }
        let command = action.settings["command"] as? String ?? "settings"
        if command == "settings" { openBuilder(gang: false); return }
        if command == "gang" { openBuilder(gang: true); return }
        let cameras = targets(for: action)
        guard !cameras.isEmpty else { openBuilder(gang: true); return }
        pendingControls.append(ControlRequest(context: context, cameras: cameras, parameter: nil, command: command,
                                              ticks: 0, reset: false, fine: false, generation: configGeneration))
        startNextControl()
    }
    private func startNextControl() {
        guard !controlRunning, !stopping else { return }
        while !pendingControls.isEmpty {
            let request = pendingControls.removeFirst()
            guard request.generation == configGeneration, actions[request.context] != nil else { continue }
            if request.parameter != nil && !request.reset && request.ticks == 0 { continue }
            controlRunning = true
            activeControlIDs = Set(request.cameras.map(\.id))
            for camera in request.cameras { cameraRevisions[camera.id, default: 0] &+= 1 }
            control.async {
                let result = self.execute(request)
                self.state.async { self.finish(request, result: result) }
            }
            return
        }
    }
    private func controlClient(_ camera: CameraConfig) -> CameraClient {
        if let cached = controlClients[camera.address] { return cached }
        let client = CameraClient(address: camera.address)
        controlClients[camera.address] = client
        return client
    }
    private func isCurrent(_ request: ControlRequest) -> Bool {
        state.sync { !stopping && configGeneration == request.generation }
    }
    private func execute(_ request: ControlRequest) -> ControlResult {
        var result = ControlResult()
        guard isCurrent(request), let sourceCamera = request.cameras.first else { return result }
        if let parameter = request.parameter {
            let source: CameraSnapshot
            let wire: Double
            do {
                source = try controlClient(sourceCamera).read()
                if request.reset && parameter == "playback" {
                    // The existing camera control uses these verified transport
                    // commands. Setting a speed alone need not start playback.
                    let key = source.key(for: parameter)
                    guard let current = source.number(key),
                          let speed = source.enumCatalog.choices[key]?.first(where: { $0.wireValue == current })?.numericValue else {
                        throw CameraError.unavailable("Playback play/pause")
                    }
                    let command = speed == 0 ? "PlayBackGo" : "PlayBackStop"
                    for camera in request.cameras {
                        guard isCurrent(request) else { return result }
                        do { result.snapshots[camera.id] = try controlClient(camera).call(command) }
                        catch { result.failures[camera.id] = error.localizedDescription }
                    }
                    return result
                } else if request.reset {
                    guard let target = source.resetValue(parameter) else { throw CameraError.unavailable("Reset for \(parameter)") }
                    wire = target
                } else {
                    wire = try source.steppedValue(parameter: parameter, ticks: request.ticks, fine: request.fine)
                }
            } catch {
                result.failures[sourceCamera.id] = error.localizedDescription
                return result
            }
            for camera in request.cameras {
                guard isCurrent(request) else { return result }
                do {
                    let client = controlClient(camera)
                    let current = camera.id == sourceCamera.id ? source : try client.read()
                    let destination = try current.convertedWireValue(wire, parameter: parameter, from: source)
                    guard isCurrent(request) else { return result }
                    result.snapshots[camera.id] = try client.set([current.key(for: parameter): destination])
                } catch { result.failures[camera.id] = error.localizedDescription }
            }
        } else if let command = request.command {
            let commandNames = ["playback":"PlaybackEnter", "live":"PlaybackExit", "previousClip":"PlaybackSkipRev", "nextClip":"PlaybackSkipFwd"]
            for camera in request.cameras {
                guard isCurrent(request) else { return result }
                do {
                    guard let name = commandNames[command] else { throw BuilderError.message("Unknown camera button.") }
                    result.snapshots[camera.id] = try controlClient(camera).call(name)
                } catch { result.failures[camera.id] = error.localizedDescription }
            }
        }
        return result
    }
    private func finish(_ request: ControlRequest, result: ControlResult) {
        controlRunning = false
        activeControlIDs.removeAll()
        // Any poll that started before this write completed is now obsolete.
        for camera in request.cameras { cameraRevisions[camera.id, default: 0] &+= 1 }
        defer { startNextControl() }
        guard request.generation == configGeneration, !stopping else { return }
        for (id, snapshot) in result.snapshots { snapshots[id] = snapshot; failures.removeValue(forKey: id) }
        for camera in request.cameras {
            if let message = result.failures[camera.id] {
                snapshots.removeValue(forKey: camera.id)
                failures[camera.id] = message
                log("\(camera.name) (\(camera.address)), \(request.parameter ?? request.command ?? "control"): \(message)")
            }
        }
        if !result.failures.isEmpty {
            let details = request.cameras.compactMap { camera in
                result.failures[camera.id].map { "\(camera.name): \($0)" }
            }.joined(separator: "; ")
            let prefix = request.cameras.count > 1 ? "\(result.failures.count)/\(request.cameras.count) cameras failed. " : ""
            alert(request.context, prefix + details)
        }
        lastFeedback.removeAll()
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
    private func renderAll() { for (context, action) in actions { render(context,action) } }
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
                lastFeedback[context] = encoded
                send(["event":"setTitle", "context":context, "payload":payload])
            }
            return
        }
        let parameter = action.settings["parameter"] as? String ?? "wb"
        let descriptions = cameras.compactMap { snapshots[$0.id]?.description(for: parameter) }
        let missing = cameras.filter { snapshots[$0.id] == nil }
        let failed = missing.filter { failures[$0.id] != nil }
        let value: String
        if activeFailure != nil { value = "FAILED" }
        else if cameras.isEmpty { value = "SELECT CAM" }
        else if !failed.isEmpty { value = cameras.count == 1 ? "OFFLINE" : "\(failed.count) OFFLINE" }
        else if !missing.isEmpty { value = "CONNECTING" }
        else if Set(descriptions).count > 1 { value = "MIXED" }
        else { value = descriptions.first ?? "UNAVAILABLE" }
        let hint: String
        if let failure = activeFailure { hint = String(failure.message.prefix(42)) }
        else if value == "MIXED" { hint = "Turn to match first camera" }
        else if !failed.isEmpty { hint = "Check network / camera IP" }
        else if parameter == "playback" { hint = "Turn: speed · Press: play/pause" }
        else { hint = "Turn: adjust · Press: reset" }
        let payload: [String:Any] = ["title":labels[parameter] ?? parameter.uppercased(), "value":value, "target":target, "hint":hint,"icon":"Images/\(parameter).png"]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), encoded != lastFeedback[context] else { return }
        lastFeedback[context] = encoded
        send(["event":"setFeedback","context":context,"payload":payload])
        let diagnostic = ["updated":ISO8601DateFormatter().string(from: Date()),"parameter":parameter,"value":value,"target":target]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options:.prettyPrinted) {
            try? data.write(to: ConfigStore.directory.appendingPathComponent("feedback-\(parameter).json"), options:.atomic)
        }
    }
}
