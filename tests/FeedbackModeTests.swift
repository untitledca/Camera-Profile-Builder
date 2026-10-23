import Foundation

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.failed(message) }
}

@main
struct FeedbackModeTests {
    static func main() throws {
        let legacy = Data("""
        {
          "cameras": [{"id":"camera-a","name":"A CAM","model":"ALEXA Mini LF","address":"127.0.0.1:12345"}],
          "selectedCameraID":"camera-a",
          "gangIDs":["camera-a"],
          "gangEnabled":true,
          "gangMode":"absolute"
        }
        """.utf8)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let original = try decoder.decode(BuilderConfig.self, from: legacy)
        try check(original.feedbackMode == .live, "Existing saved configurations default to live feedback")

        let memberwise = BuilderConfig(cameras: original.cameras, selectedCameraID: original.selectedCameraID,
                                      gangIDs: original.gangIDs, gangEnabled: original.gangEnabled,
                                      gangMode: original.gangMode)
        try check(memberwise == original, "Existing memberwise initializer remains source compatible")

        for mode in FeedbackMode.allCases {
            var config = original
            config.feedbackMode = mode
            let encoded = try encoder.encode(config)
            let decoded = try decoder.decode(BuilderConfig.self, from: encoded)
            try check(decoded == config, "Feedback mode round trips without changing camera or gang configuration")
            let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            try check(json["feedbackMode"] as? String == mode.rawValue, "Feedback mode encodes as a stable string")
            try check(decoded.cameras == original.cameras && decoded.gangIDs == original.gangIDs && decoded.gangEnabled,
                      "Feedback choices preserve saved camera identities and gang selection")
        }

        var extended = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        for value: Any in ["future-mode", NSNull(), 17, true] {
            extended["feedbackMode"] = value
            let decoded = try decoder.decode(BuilderConfig.self, from: JSONSerialization.data(withJSONObject: extended))
            try check(decoded == original, "Missing, unknown, null, or invalid feedback mode safely uses live")
        }
        try check(FeedbackMode.live.pollInterval == 1, "Live polls once per second")
        try check(FeedbackMode.reduced.pollInterval == 3, "Reduced polls every three seconds")
        try check(FeedbackMode.off.pollInterval == nil, "Off disables routine polling")
        try check(FeedbackMode.allCases.map(\.title) == ["Live", "Reduced", "Off"], "Feedback picker labels remain clear")
        print("PASS: legacy configuration, feedback mode round trips and fallback, stable camera identities, polling policy")
    }
}
