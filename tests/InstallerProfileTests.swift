import Foundation

/// Fixture archives and preference dictionaries only. These checks never call
/// Installer.install/refreshPluginIfNeeded or open the real preference domain.
@main
enum InstallerProfileTests {
    typealias Object = [String: Any]
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func reject(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(description: message)
    }

    static func read(_ url: URL) throws -> Object {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! Object
    }

    static func write(_ object: Object, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    static func archive(_ directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", directory.path, destination.path]
        try process.run(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Could not create a test archive.")
    }

    static func syntheticProfile(in directory: URL, topActions: Int, fallbackActions: Int,
                                 childActions: Int, owned: Bool = true, legacyDefault: Bool = false) throws -> URL {
        let root = directory.appendingPathComponent(UUID().uuidString + ".sdProfile")
        let launcher = UUID().uuidString
        let fallback = legacyDefault ? launcher : UUID().uuidString
        let child = UUID().uuidString
        var manifest: Object = ["Pages": ["Pages": [launcher.lowercased()], "Current": launcher.lowercased(), "Default": fallback.lowercased()]]
        if owned { manifest["InstalledByPluginUUID"] = ProfileBuilder.pluginID }
        try write(manifest, root.appendingPathComponent("manifest.json"))
        func page(_ id: String, count: Int) throws {
            let actions = Dictionary(uniqueKeysWithValues: (0..<count).map { ("\($0),0", ["UUID": "fixture.action"] as Object) })
            try write(["Controllers": [["Type": "Keypad", "Actions": actions], ["Type": "Encoder", "Actions": NSNull()]]],
                      root.appendingPathComponent("Profiles/\(id)/manifest.json"))
        }
        try page(launcher, count: topActions)
        if !legacyDefault { try page(fallback, count: fallbackActions) }
        try page(child, count: childActions)
        return root
    }

    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("InstallerProfileTests-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let camera = CameraConfig(id: "stable-a", name: "A CAM", model: "ALEXA Mini LF", address: "10.10.1.41")
        let config = BuilderConfig(cameras: [camera], selectedCameraID: camera.id,
                                   gangIDs: [camera.id], gangEnabled: true, gangMode: "absolute")
        let exports = try ProfileBuilder.generate(config: config, output: temporary.appendingPathComponent("Exports"),
                                                   pluginBundle: repository.appendingPathComponent("assets"))
        let prepared = try Installer.prepareProfiles(exports, in: temporary.appendingPathComponent("Prepared"), deviceID: "TEST-DEVICE")
        try expect(prepared.count == 3, "Expected camera, gang and combined fixture profiles.")
        for root in prepared {
            let manifest = try read(root.appendingPathComponent("manifest.json"))
            let metadata = manifest["Pages"] as! Object
            let pages = metadata["Pages"] as! [String]
            let fallback = metadata["Default"] as! String
            try expect((manifest["Device"] as? Object)?["UUID"] as? String == "TEST-DEVICE", "Preparation did not bind the target device.")
            try expect(metadata["Current"] as? String == pages.first, "Preparation must activate the launcher, not the fallback.")
            try expect(!pages.contains(fallback), "Default fallback still duplicates a launcher page.")
        }
        let newCount = try prepared.reduce(0) { try $0 + Installer.topLevelActionCount(in: $1) }
        try expect(newCount == 4, "Only one camera folder, one gang folder and the two combined folders should count.")

        func modifiedArchive(_ name: String, change: (URL, inout Object) throws -> Void) throws -> URL {
            let package = temporary.appendingPathComponent("Package-\(name)")
            let copy = package.appendingPathComponent("Profiles/\(prepared[0].lastPathComponent)")
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: prepared[0], to: copy)
            let manifestURL = copy.appendingPathComponent("manifest.json")
            var manifest = try read(manifestURL)
            try change(copy, &manifest)
            try write(manifest, manifestURL)
            let result = temporary.appendingPathComponent("\(name).streamDeckProfile")
            try archive(package, to: result)
            return result
        }
        let duplicateDefault = try modifiedArchive("duplicate-default") { _, manifest in
            var metadata = manifest["Pages"] as! Object
            metadata["Default"] = (metadata["Pages"] as! [String])[0]
            manifest["Pages"] = metadata
        }
        let missingDefault = try modifiedArchive("missing-default") { _, manifest in
            var metadata = manifest["Pages"] as! Object
            metadata["Default"] = UUID().uuidString.lowercased()
            manifest["Pages"] = metadata
        }
        let missingLauncher = try modifiedArchive("missing-launcher") { root, manifest in
            let first = ((manifest["Pages"] as! Object)["Pages"] as! [String])[0]
            try fm.removeItem(at: root.appendingPathComponent("Profiles/\(first.uppercased())"))
        }
        let duplicateLauncher = try modifiedArchive("duplicate-launcher") { _, manifest in
            var metadata = manifest["Pages"] as! Object
            let first = (metadata["Pages"] as! [String])[0]
            metadata["Pages"] = [first, first.uppercased()]
            manifest["Pages"] = metadata
        }
        for (index, bad) in [duplicateDefault, missingDefault, missingLauncher, duplicateLauncher].enumerated() {
            try reject("Preparation accepted invalid native page metadata in \(bad.lastPathComponent).") {
                _ = try Installer.prepareProfiles([bad], in: temporary.appendingPathComponent("Rejected-\(index)"), deviceID: "TEST")
            }
        }

        let old = try syntheticProfile(in: temporary.appendingPathComponent("Old"), topActions: 7,
                                       fallbackActions: 2, childActions: 99)
        let legacy = try syntheticProfile(in: temporary.appendingPathComponent("Old"), topActions: 4,
                                          fallbackActions: 0, childActions: 77, legacyDefault: true)
        let foreign = try syntheticProfile(in: temporary.appendingPathComponent("Old"), topActions: 100,
                                           fallbackActions: 10, childActions: 90, owned: false)
        let oldCount = try Installer.topLevelActionCount(in: old)
        let legacyCount = try Installer.topLevelActionCount(in: legacy)
        try expect(oldCount == 9, "Fallback actions must count; child folder actions must not count.")
        try expect(legacyCount == 4, "Legacy duplicate Default metadata must not count actions twice.")
        let original: Object = [
            "Devices": ["unchanged-device": ["brightness": 71]],
            "last_app_session_report": ["session_count": 82, "action_count": 411, "future_field": "KEEP"],
            "last_app_session_count": 82, "Unrelated": "PRESERVE"
        ]
        // Match installation's backup-before-write and whole-domain rollback:
        // this fixture stays in a temporary file and never uses UserDefaults.
        let snapshot = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        let backup = temporary.appendingPathComponent("StreamDeck-preferences.plist")
        try snapshot.write(to: backup, options: .atomic)
        let changed = try Installer.reconcilingSessionActionCount(in: original,
                                                                  removing: [old, legacy, old, foreign], adding: prepared)
        let report = changed["last_app_session_report"] as! Object
        try expect(report["action_count"] as? Int == 402, "Only the known owned 13→4 action delta should change the saved count.")
        try expect(report["session_count"] as? Int == 82 && report["future_field"] as? String == "KEEP", "Other session report fields changed.")
        for key in ["Devices", "last_app_session_count", "Unrelated"] {
            try expect(NSDictionary(dictionary: [key: changed[key]!]).isEqual([key: original[key]!]), "Unrelated preference \(key) changed.")
        }
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), options: [], format: nil) as! Object
        try expect(NSDictionary(dictionary: restored).isEqual(original), "The rollback backup did not preserve the entire original domain.")
        try expect((restored["last_app_session_report"] as? Object)?["action_count"] as? Int == 411, "Rollback must restore the original integrity count.")
        try expect((original["last_app_session_report"] as? Object)?["action_count"] as? Int == 411, "Session reconciliation mutated the original backup domain.")
        let noReport: Object = ["Other": 17]
        let withoutReport = try Installer.reconcilingSessionActionCount(in: noReport, removing: [old], adding: prepared)
        try expect(NSDictionary(dictionary: withoutReport).isEqual(noReport), "Missing reports must not invent a session baseline.")
        var tooSmall = original
        tooSmall["last_app_session_report"] = ["action_count": 1, "session_count": 82]
        try reject("An inconsistent negative baseline should fail before any installation mutations.") {
            _ = try Installer.reconcilingSessionActionCount(in: tooSmall, removing: [old, legacy], adding: prepared)
        }
        try reject("A foreign profile cannot be added to our known-owned replacement delta.") {
            _ = try Installer.reconcilingSessionActionCount(in: original, removing: [old], adding: [foreign])
        }
        print("Installer profile checks passed: separate fallback metadata, prepared launcher/device validation, invalid page rejection, owned-only session action delta, copied-folder exclusion, and complete rollback snapshot preservation. No live state was changed.")
    }
}
