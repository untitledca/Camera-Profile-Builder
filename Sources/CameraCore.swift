import Foundation
import CoreFoundation
import Darwin

struct CameraConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var model: String
    var address: String
}

struct BuilderConfig: Codable, Equatable {
    var cameras: [CameraConfig]
    var selectedCameraID: String
    var gangIDs: [String]
    var gangEnabled: Bool
    var gangMode: String
    var feedbackMode: FeedbackMode = .live

    private enum CodingKeys: String, CodingKey {
        case cameras, selectedCameraID, gangIDs, gangEnabled, gangMode, feedbackMode
    }
}

extension BuilderConfig {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cameras = try values.decode([CameraConfig].self, forKey: .cameras)
        selectedCameraID = try values.decode(String.self, forKey: .selectedCameraID)
        gangIDs = try values.decode([String].self, forKey: .gangIDs)
        gangEnabled = try values.decode(Bool.self, forKey: .gangEnabled)
        gangMode = try values.decode(String.self, forKey: .gangMode)
        feedbackMode = try values.decodeIfPresent(FeedbackMode.self, forKey: .feedbackMode) ?? .live
    }
}

enum FeedbackMode: String, Codable, CaseIterable {
    case live, reduced, off

    var title: String {
        switch self {
        case .live: return "Live"
        case .reduced: return "Reduced"
        case .off: return "Off"
        }
    }

    var pollInterval: TimeInterval? {
        switch self {
        case .live: return 1
        case .reduced: return 3
        case .off: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        self = (try? value.decode(String.self)).flatMap(Self.init(rawValue:)) ?? .live
    }
}

enum CameraError: LocalizedError {
    case invalidAddress, timeout, badResponse(String), unavailable(String), readOnly(String)
    case rejected(String), invalidValue(String), verification(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a camera IP address or hostname, optionally followed by a port."
        case .timeout: return "The camera did not respond. Check its address and your network connection."
        case .badResponse(let reason): return "The camera returned an invalid response: \(reason)"
        case .unavailable(let name): return "\(name) is not available on this camera."
        case .readOnly(let name): return "The camera currently has \(name) locked or read only."
        case .rejected(let reason): return "The camera refused the change: \(reason)"
        case .invalidValue(let reason): return "Invalid camera value: \(reason)"
        case .verification(let reason): return "The camera accepted the request but did not confirm \(reason)."
        }
    }
}

struct CameraChoice {
    let wireValue: Double
    let name: String
    let label: String
    let numericValue: Double?
}

/// Reads the camera's own generated enum ordering. The Web Remote CGI protocol
/// uses indexes into these arrays, not the numeric-looking values in enum names.
struct CameraEnumCatalog {
    var choices: [String: [CameraChoice]] = [:]

    init(source: String) {
        for (key, defaultType) in [("ExposureIndex", "ExposureIndex"),
                                   ("NDFilterPosition", "NDFilter"),
                                   ("NDFilterPositionEffective", "NDFilter"),
                                   ("PlaybackSpeedEnum", "PlaybackSpeed")] {
            let declaration = Self.capture("\\b" + key + "\\s*=\\s*\\{[^}]*?\\btype:\\s*\"([^\"]+)\"", in: source)
            let type = declaration ?? defaultType
            let escaped = NSRegularExpression.escapedPattern(for: type)
            var names: [String] = []
            let pattern = "\\b" + escaped + ":\\s*(?:\\[([^\\]]+)\\]|\"([^\"]+)\"\\.split\\(\" \"\\))"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
                if match.range(at: 1).location != NSNotFound {
                    names = Self.captures("\"([^\"]+)\"", in: (source as NSString).substring(with: match.range(at: 1)))
                } else {
                    names = (source as NSString).substring(with: match.range(at: 2)).split(separator: " ").map(String.init)
                }
            }
            choices[key] = names.enumerated().map { index, name in
                let translation = Self.capture("\\.en\\.ENUM_" + escaped + "_" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\"([^\"]*)\"", in: source)
                var label = translation ?? name.replacingOccurrences(of: "_", with: " ")
                var numeric: Double?
                if key == "ExposureIndex" {
                    numeric = Double(translation ?? name.replacingOccurrences(of: "EI_", with: ""))
                    if let number = numeric { label = Self.formatted(number) }
                } else if key.hasPrefix("NDFilter") {
                    if name == "CLEAR" { numeric = 0; label = "Clear" }
                    else {
                        // Mini LF's historical TWO_POINT_ONE token actually displays
                        // ND 1.8. The translation supplied by the camera is authoritative.
                        numeric = translation.flatMap { Self.firstNumber(in: $0) }
                        if let number = numeric { label = Self.formatted(number) }
                    }
                } else if key == "PlaybackSpeedEnum" {
                    if name == "PAUSE" { numeric = 0; label = "Paused" }
                    else if name.hasPrefix("REV_") {
                        numeric = Double(name.dropFirst(4)).map { -$0 }
                        label = "−" + String(name.dropFirst(4)) + "×"
                    } else if name.hasPrefix("FWD_") {
                        numeric = Double(name.dropFirst(4)); label = String(name.dropFirst(4)) + "×"
                    }
                }
                return CameraChoice(wireValue: Double(index), name: name, label: label, numericValue: numeric)
            }
        }
    }

    static func capture(_ pattern: String, in source: String) -> String? {
        captures(pattern, in: source).first
    }

    static func captures(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    static func firstNumber(in text: String) -> Double? {
        capture("([0-9]+(?:\\.[0-9]+)?)", in: text).flatMap(Double.init)
    }

    static func formatted(_ number: Double) -> String {
        if number.rounded() == number { return String(format: "%.0f", number) }
        return String(format: "%.3f", number).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}

struct CameraSnapshot {
    let id: Int
    let variables: [String: [String: Any]]
    let commands: [String: String]
    let enumCatalog: CameraEnumCatalog

    static let parameterKeys = ["wb": "WBCurrentKelvin", "tint": "WBCurrentColorComp",
                                "shutter": "ShutterNominal", "ei": "ExposureIndex",
                                "nd": "NDFilterPosition", "fps": "FPSNominal",
                                "playback": "PlaybackSpeedEnum"]

    init(json: [String: Any], enumSource: String = "") throws {
        try self.init(json: json, enumCatalog: CameraEnumCatalog(source: enumSource))
    }

    init(json: [String: Any], enumCatalog: CameraEnumCatalog) throws {
        guard let id = (json["id"] as? NSNumber)?.intValue,
              let variables = json["variables"] as? [String: [String: Any]], !variables.isEmpty else {
            throw CameraError.badResponse((json["ERROR"] as? String) ?? "missing camera variables")
        }
        self.id = id
        self.variables = variables
        commands = json["commands"] as? [String: String] ?? [:]
        self.enumCatalog = enumCatalog
    }

    func key(for parameter: String) -> String { Self.parameterKeys[parameter] ?? parameter }
    func value(_ key: String) -> Any? { variables[self.key(for: key)]?["value"] }
    func number(_ key: String) -> Double? {
        if let n = value(key) as? NSNumber { return n.doubleValue }
        return (value(key) as? String).flatMap(Double.init)
    }
    var commandNames: Set<String> { Set(commands.values) }

    func bounds(for parameter: String) -> ClosedRange<Double>? {
        guard let metadata = variables[key(for: parameter)],
              let lo = (metadata["min"] as? NSNumber)?.doubleValue,
              let hi = (metadata["max"] as? NSNumber)?.doubleValue, lo.isFinite, hi.isFinite, lo <= hi else { return nil }
        return lo...hi
    }

    func choices(for parameter: String) -> [CameraChoice] {
        let key = self.key(for: parameter)
        guard let metadata = variables[key] else { return [] }
        let all = enumCatalog.choices[key] ?? []
        let properties = metadata["properties"] as? [NSNumber]
        return all.filter { choice in
            guard bounds(for: key)?.contains(choice.wireValue) ?? true else { return false }
            let index = Int(choice.wireValue)
            guard let properties = properties else { return true }
            return properties.indices.contains(index) && properties[index].intValue & 3 == 3
        }
    }

    func canWrite(_ parameter: String) -> Bool {
        let key = self.key(for: parameter)
        guard let metadata = variables[key], number(key) != nil,
              let readOnly = metadata["readonly"] as? NSNumber, !readOnly.boolValue else { return false }
        if metadata["type"] as? String == "enumint", Self.parameterKeys.values.contains(key) {
            return !choices(for: key).isEmpty
        }
        return true
    }

    func description(for parameter: String) -> String {
        let key = self.key(for: parameter)
        guard let number = number(key) else { return "Unavailable" }
        if variables[key]?["type"] as? String == "enumint" {
            if let choice = enumCatalog.choices[key]?.first(where: { $0.wireValue == number }) { return choice.label }
            return "Unknown (\(CameraEnumCatalog.formatted(number)))"
        }
        let text = CameraEnumCatalog.formatted(number)
        switch key {
        case "WBCurrentKelvin": return text + "K"
        case "WBCurrentColorComp": return (number > 0 ? "+" : "") + text
        case "ShutterNominal": return text + "°"
        case "FPSNominal": return text + " fps"
        default: return text
        }
    }

    /// Returns the CGI wire value. For EI and ND this is an enum index.
    func steppedValue(parameter: String, ticks: Int, fine: Bool = false) throws -> Double {
        let key = self.key(for: parameter)
        guard variables[key] != nil, let current = number(key) else { throw CameraError.unavailable(parameter) }
        guard canWrite(key) else { throw CameraError.readOnly(parameter) }
        if variables[key]?["type"] as? String == "enumint" {
            let options = choices(for: key)
            guard let currentIndex = options.firstIndex(where: { $0.wireValue == current }) else { throw CameraError.unavailable("Current \(parameter) enum") }
            let targetIndex = max(0, min(options.count - 1, currentIndex + max(-1000, min(1000, ticks))))
            return options[targetIndex].wireValue
        }
        let step: Double
        switch key {
        case "WBCurrentKelvin": step = fine ? 10 : 100
        case "WBCurrentColorComp": step = fine ? 0.1 : 0.5
        case "ShutterNominal": step = 0.1
        case "FPSNominal": step = fine ? 0.1 : 1
        default: throw CameraError.unavailable(parameter)
        }
        var target = ((current + Double(max(-1000, min(1000, ticks))) * step) * 1000).rounded() / 1000
        if let range = bounds(for: key) { target = max(range.lowerBound, min(range.upperBound, target)) }
        return target
    }

    func resetValue(_ parameter: String) -> Double? {
        let key = self.key(for: parameter)
        guard canWrite(key) else { return nil }
        let target: Double
        switch key {
        case "WBCurrentKelvin": target = 5600
        case "WBCurrentColorComp": target = 0
        case "ShutterNominal": target = 180
        case "FPSNominal": target = 24
        case "ExposureIndex": return choices(for: key).first(where: { $0.numericValue == 800 })?.wireValue
        case "NDFilterPosition", "PlaybackSpeedEnum": return choices(for: key).first(where: { $0.numericValue == 0 })?.wireValue
        default: return nil
        }
        return bounds(for: key)?.contains(target) == false ? nil : target
    }

    func resetValue(parameter: String) -> Double? { resetValue(parameter) }

    /// Transfers an absolute setting between cameras by its meaning, never by
    /// assuming that two firmwares assign the same enum index to that setting.
    func convertedWireValue(_ wire: Double, parameter: String, from source: CameraSnapshot) throws -> Double {
        let sourceKey = source.key(for: parameter)
        let targetKey = key(for: parameter)
        var semantic = wire
        if source.variables[sourceKey]?["type"] as? String == "enumint" {
            guard let value = source.enumCatalog.choices[sourceKey]?.first(where: { $0.wireValue == wire })?.numericValue else {
                throw CameraError.unavailable("Meaning of \(parameter) on the source camera")
            }
            semantic = value
        }
        var target = semantic
        if variables[targetKey]?["type"] as? String == "enumint" {
            guard let value = choices(for: targetKey).first(where: { choice in
                choice.numericValue.map { abs($0 - semantic) < 0.001 } ?? false
            })?.wireValue else {
                throw CameraError.unavailable("Matching \(parameter) setting on this camera")
            }
            target = value
        }
        _ = try validatedValues([targetKey: target])
        return target
    }

    func validatedValues(_ input: [String: Any]) throws -> [String: Any] {
        var output: [String: Any] = [:]
        guard !input.isEmpty else { throw CameraError.invalidValue("No settings were provided") }
        for (parameter, value) in input {
            let key = self.key(for: parameter)
            guard let metadata = variables[key] else { throw CameraError.unavailable(key) }
            guard let readOnly = metadata["readonly"] as? NSNumber, !readOnly.boolValue else { throw CameraError.readOnly(key) }
            let type = metadata["type"] as? String ?? ""
            if type == "bool" {
                guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw CameraError.invalidValue("\(key) requires true or false") }
                output[key] = n.boolValue
                continue
            }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw CameraError.invalidValue("\(key) requires a finite number")
            }
            let number = n.doubleValue
            if let range = bounds(for: key), !range.contains(number) { throw CameraError.invalidValue("\(key) must be between \(range.lowerBound) and \(range.upperBound)") }
            if ["int", "long", "enumint"].contains(type), number.rounded() != number { throw CameraError.invalidValue("\(key) requires a whole number") }
            if type == "enumint" {
                if Self.parameterKeys.values.contains(key) {
                    guard choices(for: key).contains(where: { $0.wireValue == number }) else { throw CameraError.invalidValue("\(key) is not a supported selectable value") }
                } else if let properties = metadata["properties"] as? [NSNumber] {
                    let index = Int(number)
                    guard properties.indices.contains(index), properties[index].intValue & 3 == 3 else { throw CameraError.invalidValue("\(key) is disabled on this camera") }
                }
            }
            output[key] = number
        }
        return output
    }

    /// Builds a validated desired state for coalescing later adjustments. This
    /// value has not been read back from the camera and must remain distinct
    /// from the last confirmed snapshot in callers.
    func applying(_ values: [String: Any]) throws -> CameraSnapshot {
        guard !values.isEmpty else { return self }
        let payload = try validatedValues(values)
        var desired = variables
        for (key, value) in payload { desired[key]?["value"] = value }
        return try CameraSnapshot(json: ["id": id, "variables": desired, "commands": commands], enumCatalog: enumCatalog)
    }
}

/// Synchronous transport for a background queue. It never updates UI, and it
/// never optimistically replaces camera feedback with an unconfirmed value.
final class CameraClient {
    let address: String
    private let session: URLSession
    private var enumSource = ""
    private var enumCatalog = CameraEnumCatalog(source: "")
    private var loadedEnums = false
    private var lastSnapshot: CameraSnapshot?
    private let timeout: TimeInterval
    private let readTasksLock = NSLock()
    private var readTasks: [Int: URLSessionDataTask] = [:]

    static let supportedCommandNames: Set<String> = ["PlayBackPrepare", "PlayBackGo", "PlayBackStop", "PlayBackEnd", "PlayBackPos", "PlayBackSkipClip", "RecordingStart", "RecordingStop", "PlaybackEnter", "PlaybackExit", "PlaybackSkipRev", "PlaybackSkipFwd"]
    private static let preferredCommands = ["PlayBackPrepare": "_EeUkIwIBEeSgptigTra4vQ", "PlayBackGo": "_7q_F4cHREeStK8NH8ZPGbQ", "PlayBackStop": "__WRr68HREeStK8NH8ZPGbQ", "PlayBackEnd": "_cCCFscHSEeStK8NH8ZPGbQ"]

    init(address: String, timeout: TimeInterval = 2.5, session: URLSession? = nil) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeout = timeout
        if let session = session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout + 0.5
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.connectionProxyDictionary = [:]
            let callbackQueue = OperationQueue()
            callbackQueue.name = "CameraProfileBuilder.CameraHTTP"
            callbackQueue.maxConcurrentOperationCount = 2
            self.session = URLSession(configuration: config, delegate: nil, delegateQueue: callbackQueue)
        }
    }

    static func validateAddress(_ address: String) throws -> URL {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(where: { $0.isWhitespace }),
              address.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\@?#%")) == nil,
              !address.contains("://") else { throw CameraError.invalidAddress }
        var host: String
        var port: Int?
        if address.hasPrefix("[") {
            guard let closing = address.firstIndex(of: "]") else { throw CameraError.invalidAddress }
            host = String(address[address.index(after: address.startIndex)..<closing])
            var ipv6 = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { throw CameraError.invalidAddress }
            let tail = String(address[address.index(after: closing)...])
            if !tail.isEmpty {
                guard tail.hasPrefix(":"), let parsed = Int(tail.dropFirst()), (1...65535).contains(parsed) else { throw CameraError.invalidAddress }
                port = parsed
            }
            host = "[\(host)]"
        } else {
            let pieces = address.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count) else { throw CameraError.invalidAddress }
            host = String(pieces[0])
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), (1...65535).contains(parsed) else { throw CameraError.invalidAddress }
                port = parsed
            }
            guard host.count <= 253, !host.isEmpty else { throw CameraError.invalidAddress }
            if host.allSatisfy({ $0.isNumber || $0 == "." }) {
                let octets = host.split(separator: ".", omittingEmptySubsequences: false)
                guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && Int($0).map { (0...255).contains($0) } == true }) else { throw CameraError.invalidAddress }
            } else {
                let labels = host.split(separator: ".", omittingEmptySubsequences: false)
                guard labels.allSatisfy({ label in
                    !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" && label.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-" }
                }) else { throw CameraError.invalidAddress }
            }
        }
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = port
        guard let url = components.url, url.host != nil else { throw CameraError.invalidAddress }
        return url
    }

    static func validIPAddress(_ address: String) -> Bool { (try? validateAddress(address)) != nil }

    func read() throws -> CameraSnapshot {
        // update.cgi is a long poll and may block for more than three seconds
        // without changes. A complete snapshot provides bounded dial refresh,
        // current readonly flags and recording-format-dependent limits.
        let json = try requestJSON(path: "/all.cgi")
        if !loadedEnums {
            enumSource = (try? requestText(path: "/js/all-dg.min.js")) ?? ""
            loadedEnums = !enumSource.isEmpty
            if loadedEnums { enumCatalog = CameraEnumCatalog(source: enumSource) }
        }
        let snapshot = try CameraSnapshot(json: json, enumCatalog: enumCatalog)
        lastSnapshot = snapshot
        return snapshot
    }

    @discardableResult
    func set(_ values: [String: Any]) throws -> CameraSnapshot {
        let current = try read()
        let payload = try submit(values, using: current)
        // An accepted HTTP write is followed by authoritative camera feedback.
        // A few settings settle after the CGI response; don't repeat the write.
        var snapshot = try read()
        for attempt in 0..<3 {
            let mismatches = payload.keys.filter { key in
                guard let expected = payload[key] as? NSNumber, let actual = snapshot.number(key) else { return true }
                return abs(expected.doubleValue - actual) > 0.001
            }
            if mismatches.isEmpty { return snapshot }
            if attempt == 2 { throw CameraError.verification(mismatches.joined(separator: ", ")) }
            Thread.sleep(forTimeInterval: 0.08)
            snapshot = try read()
        }
        return snapshot
    }

    @discardableResult
    func call(_ command: String, values: [String: Any] = [:]) throws -> CameraSnapshot {
        let current = try read()
        try submitCommand(command, using: current, values: values)
        return try read()
    }

    /// Validates against a recent snapshot and posts once without fetching
    /// camera state. Acceptance is not confirmation; callers verify separately.
    @discardableResult
    func submit(_ values: [String: Any], using current: CameraSnapshot) throws -> [String: Any] {
        let payload = try current.validatedValues(values)
        let response = try requestJSON(path: "/set.cgi", body: payload)
        guard (response["result"] as? NSNumber)?.intValue == 1 else { throw CameraError.rejected(Self.reason(response)) }
        return payload
    }

    /// Resolves only commands advertised by the supplied firmware snapshot.
    /// Submission is deliberately separate from asynchronous camera readback.
    func submitCommand(_ command: String, using current: CameraSnapshot, values: [String: Any] = [:]) throws {
        let aliases = ["PlaybackEnter": "PlayBackPrepare", "PlaybackExit": "PlayBackEnd", "PlaybackSkipRev": "PlayBackSkipClip", "PlaybackSkipFwd": "PlayBackSkipClip"]
        let name = current.commands[command] ?? aliases[command] ?? command
        guard Self.supportedCommandNames.contains(name), current.commandNames.contains(name) else { throw CameraError.unavailable(command) }
        let commandID: String
        if current.commands[command] != nil { commandID = command }
        else if command == "PlaybackSkipRev", current.commands["_BJbzscJjEeSbpa7lQ8OAJw"] == name { commandID = "_BJbzscJjEeSbpa7lQ8OAJw" }
        else if command == "PlaybackSkipFwd", current.commands["_H_V7l8JjEeSbpa7lQ8OAJw"] == name { commandID = "_H_V7l8JjEeSbpa7lQ8OAJw" }
        else if let preferred = Self.preferredCommands[name], current.commands[preferred] == name { commandID = preferred }
        else { throw CameraError.unavailable("Verified \(name) command on this firmware") }
        var payloadValues = values
        if name == "PlayBackPrepare", values.isEmpty {
            // The verified Mini LF preparation command selects card B. Resolve
            // its live table version, rather than copying an old script's value.
            guard (current.number("ClipCountCardB") ?? 0) > 0 else { throw CameraError.unavailable("Recorded clips on camera media") }
            guard let version = current.number("ClipTableCardBVersion") else { throw CameraError.unavailable("Clip list version") }
            payloadValues = ["PlaybackMediumSelected_Local": 2, "ClipTableCardBVersion": version]
        }
        guard JSONSerialization.isValidJSONObject(payloadValues), payloadValues.keys.allSatisfy({ $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }) else {
            throw CameraError.invalidValue("Unsupported command parameters")
        }
        let response = try requestJSON(path: "/call.cgi", body: ["command": commandID, "set": payloadValues])
        // The camera's CamCom treats nonnegative call.cgi results as accepted.
        // Playback's own controller does not issue WaitForCommandResult; that
        // separate wait.cgi operation is used by list edits and file actions.
        // A later read observes any asynchronous state change; acceptance alone
        // does not imply that the command has finished.
        guard let result = response["result"] as? NSNumber, result.intValue >= 0 else { throw CameraError.rejected(Self.reason(response)) }
    }

    /// A newly queued command may interrupt background polling. Never cancel
    /// POST requests: retrying an interrupted write could apply it twice.
    func cancelPendingReads() {
        readTasksLock.lock()
        let pending = Array(readTasks.values)
        readTasksLock.unlock()
        for task in pending { task.cancel() }
    }

    private static func reason(_ response: [String: Any]) -> String {
        (response["error"] as? String) ?? (response["ERROR"] as? String) ?? "result \(response["result"].map(String.init(describing:)) ?? "missing")"
    }

    private func requestJSON(path: String, body: [String: Any]? = nil) throws -> [String: Any] {
        let data = try request(path: path, body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CameraError.badResponse("expected JSON") }
        if let message = json["ERROR"] as? String { throw CameraError.badResponse(message) }
        return json
    }

    private func requestText(path: String) throws -> String {
        guard let text = String(data: try request(path: path), encoding: .utf8) else { throw CameraError.badResponse("expected UTF-8") }
        return text
    }

    private func request(path: String, body: [String: Any]? = nil) throws -> Data {
        let base = try Self.validateAddress(address)
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw CameraError.invalidAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let body = body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let box = CameraHTTPResult()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data; box.response = response; box.error = error
            semaphore.signal()
        }
        if body == nil {
            readTasksLock.lock()
            readTasks[task.taskIdentifier] = task
            readTasksLock.unlock()
        }
        defer {
            if body == nil {
                readTasksLock.lock()
                readTasks.removeValue(forKey: task.taskIdentifier)
                readTasksLock.unlock()
            }
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 0.5) == .success else { task.cancel(); throw CameraError.timeout }
        if let error = box.error {
            if (error as NSError).code == NSURLErrorTimedOut { throw CameraError.timeout }
            throw error
        }
        guard let response = box.response as? HTTPURLResponse, (200...299).contains(response.statusCode), let data = box.data else {
            throw CameraError.badResponse("HTTP \((box.response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= 8 * 1024 * 1024 else { throw CameraError.badResponse("response too large") }
        return data
    }
}

private final class CameraHTTPResult: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}
