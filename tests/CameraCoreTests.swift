import Foundation

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.failed(message) }
}
private func mustThrow(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure.failed(message)
}
private func requestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        if count <= 0 { break }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}

private final class CameraMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw TestFailure.failed("No mock handler") }
            let data = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct CameraCoreTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("tests/fixtures/camera-enums.js"), encoding: .utf8)
        let fixture = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/camera.json"))
        let json = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        let snapshot = try CameraSnapshot(json: json, enumSource: source)

        for address in ["10.10.1.41", "10.10.1.41:8080", "alexa-mini.local", "camera-a", "[::1]:8080"] {
            _ = try CameraClient.validateAddress(address)
        }
        for address in ["", "http://10.10.1.41", "10.10.1.256", "10.10.1", "camera/path", "camera:0", "camera:65536", "camera:abc", "camera@evil", "camera?query", "bad host", "-bad.local", "[garbage]"] {
            try mustThrow("Accepted invalid address \(address)") { _ = try CameraClient.validateAddress(address) }
        }
        try check(snapshot.description(for: "wb") == "5600K", "White balance feedback")
        try check(snapshot.description(for: "ei") == "800", "EI wire 7 must display 800")
        try check(snapshot.description(for: "shutter") == "180°", "Shutter feedback")
        try check(snapshot.description(for: "playback") == "Paused", "Playback wire 10 must display paused")
        try check(snapshot.choices(for: "nd").last?.label == "1.8", "ND translation overrides historical TWO_POINT_ONE token")
        try check(try snapshot.steppedValue(parameter: "ei", ticks: 1) == 8, "EI increase uses wire index, not EI literal")
        try check(snapshot.resetValue("ei") == 7, "EI reset resolves 800 to wire 7")
        try check(try snapshot.steppedValue(parameter: "wb", ticks: -1000) == 2000, "WB respects minimum")
        try check(try snapshot.steppedValue(parameter: "fps", ticks: 1000) == 40, "FPS uses current recording format maximum")
        try check(try snapshot.steppedValue(parameter: "tint", ticks: 1, fine: true) == 0.1, "Fine tint precision")
        try check(try snapshot.steppedValue(parameter: "tint", ticks: 1) == 0.5, "Normal tint tick preserves the existing half CC step")
        try check(try snapshot.steppedValue(parameter: "shutter", ticks: 1) == 180.1, "Normal shutter tick preserves the existing tenth degree step")
        try check(try snapshot.steppedValue(parameter: "shutter", ticks: 1, fine: true) == 180.1, "Fine shutter uses a safe tenth degree")
        try check(try snapshot.steppedValue(parameter: "fps", ticks: 1) == 31, "Normal FPS tick is one frame per second")
        try mustThrow("EI literal must never be sent") { _ = try snapshot.validatedValues(["ei": 800]) }
        try mustThrow("Read only values cannot be sent") { _ = try snapshot.validatedValues(["FPSEffective": 24]) }
        try mustThrow("Boolean cannot masquerade as numeric") { _ = try snapshot.validatedValues(["wb": true]) }
        try mustThrow("Nonfinite values are rejected") { _ = try snapshot.validatedValues(["wb": Double.nan]) }
        try mustThrow("Boolean fields require booleans") { _ = try snapshot.validatedValues(["ExposurePreferenceIsAngle": 1]) }
        let unknownEnums = try CameraSnapshot(json: json)
        try check(!unknownEnums.canWrite("ei"), "Missing enum definitions must disable ambiguous EI writes")

        let reorderedSource = source.replacingOccurrences(of: "EI_640 EI_800", with: "EI_800 EI_640")
        let reordered = try CameraSnapshot(json: json, enumSource: reorderedSource)
        try check(try reordered.convertedWireValue(7, parameter: "ei", from: snapshot) == 6, "Gang matches EI meaning across enum orderings")
        var limitedJSON = json
        var limitedVariables = json["variables"] as! [String: [String: Any]]
        limitedVariables["WBCurrentKelvin"]?["max"] = 5000
        limitedJSON["variables"] = limitedVariables
        let limited = try CameraSnapshot(json: limitedJSON, enumSource: source)
        try mustThrow("Absolute gang setting outside a camera's limits must fail") { _ = try limited.convertedWireValue(5600, parameter: "wb", from: snapshot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CameraMockProtocol.self]
        let session = URLSession(configuration: configuration)
        var cameraJSON = json
        var posts = 0
        var acceptWrite = true
        var updateFeedback = true
        var callResult = 1
        var lastCall: [String: Any] = [:]
        CameraMockProtocol.handler = { request in
            switch request.url!.path {
            case "/js/all-dg.min.js": return Data(source.utf8)
            case "/all.cgi": return try JSONSerialization.data(withJSONObject: cameraJSON)
            case "/set.cgi":
                posts += 1
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                if acceptWrite && updateFeedback {
                    var vars = cameraJSON["variables"] as! [String: [String: Any]]
                    for (key, value) in body { vars[key]?["value"] = value }
                    cameraJSON["variables"] = vars
                }
                return try JSONSerialization.data(withJSONObject: ["result": acceptWrite ? 1 : 0])
            case "/call.cgi":
                posts += 1
                lastCall = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                return try JSONSerialization.data(withJSONObject: ["result": callResult])
            default: throw TestFailure.failed("Unexpected request \(request.url!)")
            }
        }
        let camera = CameraClient(address: "10.10.1.41", session: session)
        let changed = try camera.set(["wb": 5700])
        try check(changed.description(for: "wb") == "5700K", "Write returns verified camera feedback")
        try check(posts == 1, "Exactly one write")
        acceptWrite = false
        try mustThrow("A refused set.cgi result must fail") { _ = try camera.set(["wb": 5800]) }
        try check(posts == 2, "A refused write is not retried")
        acceptWrite = true; updateFeedback = false
        try mustThrow("Unconfirmed optimistic feedback must fail") { _ = try camera.set(["wb": 5900]) }
        try check(posts == 3, "Verification retries reads only")
        try mustThrow("Unknown camera command must fail") { _ = try camera.call("FactoryDefault") }
        try check(posts == 3, "Unsupported commands never post")
        _ = try camera.call("PlayBackGo")
        try check(lastCall["command"] as? String == "_7q_F4cHREeStK8NH8ZPGbQ", "Resolve verified play command")
        _ = try camera.call("PlaybackSkipRev")
        try check(lastCall["command"] as? String == "_BJbzscJjEeSbpa7lQ8OAJw", "Resolve previous clip alias")
        callResult = 0
        let acceptedCommand = try camera.call("PlayBackStop")
        try check(acceptedCommand.number("PlaybackSpeed") == 0, "Nonnegative accepted command returns actual feedback without an undocumented wait")
        let beforeEmptyPlayback = posts
        try mustThrow("Playback without recorded clips must fail clearly") { _ = try camera.call("PlaybackEnter") }
        try check(posts == beforeEmptyPlayback, "No playback request without media")
        session.invalidateAndCancel()
        print("PASS: fixture mapping, address validation, camera limits, semantic gang conversion, refusal handling and verified feedback")

        if CommandLine.arguments.contains("--live") {
            let client = CameraClient(address: "10.10.1.41")
            let start = Date()
            let live = try client.read()
            let initial = Date().timeIntervalSince(start)
            print("LIVE READ ONLY: WB \(live.description(for: "wb")), tint \(live.description(for: "tint")), shutter \(live.description(for: "shutter")), EI \(live.description(for: "ei")), ND \(live.description(for: "nd")), FPS \(live.description(for: "fps"))")
            if CommandLine.arguments.contains("--benchmark") {
                let parseStart = Date()
                for _ in 0..<5 { _ = CameraEnumCatalog(source: source) }
                let parseAverage = Date().timeIntervalSince(parseStart) / 5
                let pollStart = Date()
                for _ in 0..<5 { _ = try client.read() }
                let pollAverage = Date().timeIntervalSince(pollStart) / 5
                print(String(format: "PERFORMANCE: first read + JS %.1f ms; fixture enum parse %.1f ms; cached live read %.1f ms", initial * 1000, parseAverage * 1000, pollAverage * 1000))
            }
        }
    }
}
