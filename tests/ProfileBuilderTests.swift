import Foundation

/// Creates and inspects export archives only. No Stream Deck state or camera
/// transport is opened. The closure checks model copying a single folder into
/// an unrelated profile: all camera controls and navigation must be descendants.
@main
enum ProfileBuilderTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    typealias Object = [String: Any]

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func object(at url: URL) throws -> Object {
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Object else {
            throw Failure(description: "Invalid JSON object at \(url.path)")
        }
        return result
    }

    static func actions(in page: Object, controller: String? = nil) -> [Object] {
        (page["Controllers"] as? [Object] ?? []).filter {
            controller == nil || $0["Type"] as? String == controller
        }.flatMap { Array(($0["Actions"] as? [String: Object] ?? [:]).values) }
    }

    static func folderID(_ action: Object) -> String? {
        guard action["UUID"] as? String == "com.elgato.streamdeck.profile.openchild" else { return nil }
        return (action["Settings"] as? Object)?["ProfileUUID"] as? String
    }

    static func inspectFolder(_ id: String, cameraID: String, pages: [String: Object],
                              topLevelIDs: Set<String>, seen: inout Set<String>,
                              parameters: inout Set<String>, commands: inout Set<String>) throws {
        try expect(!topLevelIDs.contains(id), "A child folder leaked into the profile's top-level page list.")
        try expect(seen.insert(id).inserted, "Folder navigation contains a cycle or shared child.")
        guard let page = pages[id] else { throw Failure(description: "Folder refers to missing page \(id).") }
        let keys = actions(in: page, controller: "Keypad")
        try expect(keys.filter { $0["UUID"] as? String == "com.elgato.streamdeck.profile.backtoparent" }.count == 1,
                   "Every folder must have one native parent-folder action.")
        for action in actions(in: page) {
            let uuid = action["UUID"] as? String ?? ""
            try expect(!uuid.hasPrefix("com.elgato.streamdeck.page."),
                       "Copied folder navigation must not depend on surrounding profile pages.")
            if let child = folderID(action) {
                try inspectFolder(child, cameraID: cameraID, pages: pages, topLevelIDs: topLevelIDs,
                                  seen: &seen, parameters: &parameters, commands: &commands)
            } else if uuid.hasPrefix(ProfileBuilder.pluginID + ".") {
                let settings = action["Settings"] as? [String: String] ?? [:]
                try expect(settings["cameraID"] == cameraID, "Copying changed a stable camera target.")
                if let parameter = settings["parameter"] { parameters.insert(parameter) }
                if let command = settings["command"] { commands.insert(command) }
            } else {
                try expect(uuid == "com.elgato.streamdeck.profile.backtoparent", "Unexpected external navigation in camera folder.")
                try expect((action["Settings"] as? Object)?.isEmpty == true,
                           "Parent navigation must follow the native folder stack, not a fixed profile ID.")
            }
        }
    }

    static func unpack(_ archive: URL, to directory: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Could not unpack export archive.")
        let roots = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Profiles"),
                                                               includingPropertiesForKeys: nil)
        try expect(roots.count == 1, "An export must contain exactly one profile root.")
        return roots[0]
    }

    static func inspect(_ archive: URL, to directory: URL, expectedTargets: Set<String>,
                        expectedName: String, combined: Bool = false) throws {
        let profile = try unpack(archive, to: directory)
        let manifest = try object(at: profile.appendingPathComponent("manifest.json"))
        try expect(manifest["Name"] as? String == expectedName, "Unexpected profile ordering or name.")
        try expect(manifest["InstalledByPluginUUID"] as? String == ProfileBuilder.pluginID, "Export lost ownership marker.")
        let topLevel = manifest["Pages"] as? Object ?? [:]
        let topLevelIDs = Set(topLevel["Pages"] as? [String] ?? [])
        try expect(topLevelIDs.count == (combined ? 2 : 1), "Unexpected launcher page count.")
        let fallbackID = topLevel["Default"] as? String ?? ""
        try expect(UUID(uuidString: fallbackID) != nil && !topLevelIDs.contains(fallbackID),
                   "The fallback Default screen must be separate from launcher pages.")
        try expect(topLevelIDs.contains(topLevel["Current"] as? String ?? ""), "Current launcher page is missing.")
        let directories = try FileManager.default.contentsOfDirectory(at: profile.appendingPathComponent("Profiles"),
                                                                     includingPropertiesForKeys: nil)
        var pages: [String: Object] = [:]
        for screen in directories {
            let page = try object(at: screen.appendingPathComponent("manifest.json"))
            pages[screen.lastPathComponent.lowercased()] = page
            for action in actions(in: page) {
                for state in action["States"] as? [Object] ?? [] {
                    if let image = state["Image"] as? String {
                        try expect(FileManager.default.fileExists(atPath: screen.appendingPathComponent(image).path),
                                   "The copied folder is missing a custom button icon.")
                    }
                }
            }
        }
        try expect(pages[fallbackID] != nil && actions(in: pages[fallbackID] ?? [:]).isEmpty,
                   "The separate fallback screen must exist and remain empty.")
        var seen = topLevelIDs.union([fallbackID])
        var foundTargets: Set<String> = []
        for launcherID in topLevelIDs {
            guard let launcher = pages[launcherID] else { throw Failure(description: "Launcher page missing.") }
            try expect(actions(in: launcher, controller: "Encoder").isEmpty,
                       "Camera dials must be enclosed inside the copyable folder.")
            for action in actions(in: launcher) {
                guard let childID = folderID(action) else {
                    try expect(combined && (action["UUID"] as? String ?? "").hasPrefix("com.elgato.streamdeck.page."),
                               "Individual profiles should contain one camera folder only.")
                    continue
                }
                guard let child = pages[childID],
                      let pluginAction = actions(in: child).first(where: { ($0["UUID"] as? String ?? "").hasPrefix(ProfileBuilder.pluginID + ".") }),
                      let cameraID = (pluginAction["Settings"] as? Object)?["cameraID"] as? String else {
                    throw Failure(description: "Camera folder has no camera actions.")
                }
                try expect(foundTargets.insert(cameraID).inserted, "Camera folder target is duplicated.")
                var parameters: Set<String> = []
                var commands: Set<String> = []
                try inspectFolder(childID, cameraID: cameraID, pages: pages, topLevelIDs: topLevelIDs,
                                  seen: &seen, parameters: &parameters, commands: &commands)
                try expect(parameters == Set(["wb", "playback", "tint", "shutter", "ei", "nd", "fps"]),
                           "A copied camera folder must include all seven live dial controls.")
                try expect(commands == Set(["settings", "gang", "playback", "live", "previousClip", "nextClip"]),
                           "A copied camera folder must include all camera buttons.")
                let mainDials = (child["Controllers"] as? [Object] ?? []).first { $0["Type"] as? String == "Encoder" }?["Actions"] as? [String: Object] ?? [:]
                for (position, parameter) in ["0,0": "wb", "1,0": "playback", "2,0": "tint", "3,0": "shutter"] {
                    try expect((mainDials[position]?["Settings"] as? Object)?["parameter"] as? String == parameter,
                               "The familiar camera dial ordering changed.")
                }
            }
        }
        try expect(foundTargets == expectedTargets, "Profile folders point to the wrong cameras.")
        try expect(seen == Set(pages.keys), "An exported screen is not reachable by copying a native camera folder.")
    }

    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("ProfileBuilderTests-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let icons = repository.appendingPathComponent("assets")
        // Seven cameras force the combined folder collection onto two launcher
        // pages and exercise the boundary between page and folder navigation.
        let cameras = (0..<7).map { CameraConfig(id: "stable-camera-\($0)", name: "\(Character(UnicodeScalar(65 + $0)!)) CAM", model: "ALEXA Mini LF", address: "10.10.1.\(41 + $0)") }
        let config = BuilderConfig(cameras: cameras, selectedCameraID: cameras[0].id,
                                   gangIDs: cameras.map(\.id), gangEnabled: true, gangMode: "absolute")
        let archives = try ProfileBuilder.generate(config: config, output: temporary.appendingPathComponent("Exports"), pluginBundle: icons)
        try expect(archives.count == cameras.count + 2, "Export camera + gang + combined profile count is wrong.")
        for (index, camera) in cameras.enumerated() {
            try inspect(archives[index], to: temporary.appendingPathComponent("Unpacked-\(index)"),
                        expectedTargets: [camera.id], expectedName: "\(camera.name) • Camera")
        }
        try inspect(archives[cameras.count], to: temporary.appendingPathComponent("Unpacked-gang"),
                    expectedTargets: ["gang"], expectedName: "GANG • Cameras")
        try inspect(archives.last!, to: temporary.appendingPathComponent("Unpacked-combined"),
                    expectedTargets: Set(cameras.map(\.id) + ["gang"]), expectedName: "Camera Folders", combined: true)

        let empty = BuilderConfig(cameras: [], selectedCameraID: "", gangIDs: [], gangEnabled: false, gangMode: "absolute")
        let setup = try ProfileBuilder.generate(config: empty, output: temporary.appendingPathComponent("Setup"), pluginBundle: icons)
        try expect(setup.count == 1, "Empty configuration should produce only the setup profile.")
        let setupRoot = try unpack(setup[0], to: temporary.appendingPathComponent("Unpacked-setup"))
        let setupManifest = try object(at: setupRoot.appendingPathComponent("manifest.json"))
        try expect(setupManifest["Name"] as? String == "Camera Setup", "Empty configuration lost setup profile.")
        print("Profile export checks passed: native folder closure, nested exposure, all seven dials/buttons, camera IDs, icons, combined pagination, installer ordering, and empty setup. No live state was changed.")
    }
}
