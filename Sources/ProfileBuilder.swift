import Foundation

/// Produces portable Stream Deck + profiles. Camera addresses live in the shared
/// builder configuration; a profile refers to a stable camera ID so an address
/// can be corrected without rebuilding every action.
enum ProfileBuilder {
    static let pluginID = "com.atomfilmlab.camera-control"
    private static let model = "20GBD9901"

    enum BuildError: LocalizedError {
        case missingIcon(String)
        case archiveFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingIcon(let name):
                return "The profile icon ‘\(name)’ is missing. Reinstall Camera Profile Builder."
            case .archiveFailed(let detail):
                return "The Stream Deck profile could not be packaged: \(detail)"
            }
        }
    }

    /// Creates one profile per camera, a Gang profile, and a convenience profile
    /// containing the same camera folders. Every control is a descendant of its
    /// native Stream Deck folder, so copying that key carries the entire camera
    /// control tree into another profile. Camera IDs remain stable when copied.
    /// With no cameras configured this produces an app-opening setup profile.
    /// `pluginBundle` may be the .sdPlugin itself or a resource folder containing
    /// its Images/reference-icons directory.
    static func generate(config: BuilderConfig, output: URL, pluginBundle: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = fm.temporaryDirectory.appendingPathComponent("CameraProfiles-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }

        let cameras = config.cameras.map { FolderTarget(name: $0.name, cameraID: $0.id) }
        var targets: [(name: String, folders: [FolderTarget])] = cameras.map {
            (name: "\($0.name) • Camera", folders: [$0])
        }
        if config.cameras.isEmpty {
            targets.append((name: "Camera Setup", folders: []))
        } else {
            let gang = FolderTarget(name: "GANG", cameraID: "gang")
            targets.append((name: "GANG • Cameras", folders: [gang]))
            // Keep individual camera and Gang ordering for Installer's selected
            // camera activation. The combined source for copying is always last.
            targets.append((name: "Camera Folders", folders: cameras + [gang]))
        }

        var results: [URL] = []
        var usedNames: Set<String> = []
        for (index, target) in targets.enumerated() {
            let staging = temporary.appendingPathComponent("profile-\(index)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try writeProfile(name: target.name, folders: target.folders,
                             to: staging, pluginBundle: pluginBundle)

            let base = safeFilename(target.name)
            var unique = base
            var suffix = 2
            while usedNames.contains(unique.lowercased()) {
                unique = "\(base) \(suffix)"
                suffix += 1
            }
            usedNames.insert(unique.lowercased())
            let destination = output.appendingPathComponent(unique + ".streamDeckProfile")
            let packed = temporary.appendingPathComponent("packed-\(index).streamDeckProfile")
            try archive(directory: staging, to: packed)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: packed, to: destination)
            results.append(destination)
        }
        return results
    }

    private struct FolderTarget {
        let name: String
        let cameraID: String
    }

    private static func writeProfile(name: String, folders: [FolderTarget],
                                     to staging: URL, pluginBundle: URL) throws {
        let fm = FileManager.default
        let rootID = freshID()
        // Six folders leave two slots for page navigation in large collections.
        // Only these launcher pages are real pages; all control screens below
        // them are native child folders, deliberately absent from Pages.Pages.
        let launcherIDs = (0..<max(1, (folders.count + 5) / 6)).map { _ in freshID() }
        let mainID = launcherIDs[0]
        // Stream Deck 7 stores a separate legacy/fallback screen in Default.
        // Reusing a launcher ID here makes its loader map that page twice.
        let fallbackID = freshID()
        let profileRoot = staging.appendingPathComponent("Profiles/\(rootID).sdProfile", isDirectory: true)
        try fm.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "Device": ["Model": model, "UUID": freshID()],
            "InstalledByPluginUUID": pluginID,
            "Name": name,
            "Pages": ["Current": mainID.lowercased(), "Default": fallbackID.lowercased(), "Pages": launcherIDs.map { $0.lowercased() }],
            "Version": "3.0"
        ]
        try writeJSON(manifest, to: profileRoot.appendingPathComponent("manifest.json"))
        try writePage(id: fallbackID, name: "", keys: [:], dials: [:],
                      profileRoot: profileRoot, pluginBundle: pluginBundle)
        try writeJSON([
            "AppVersion": "7.4.2.22730", "DeviceModel": model,
            "DeviceSettings": NSNull(), "FormatVersion": 1,
            "OSType": "macOS", "OSVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "RequiredPlugins": [pluginID, "com.elgato.streamdeck.page"]
        ], to: staging.appendingPathComponent("package.json"))

        if folders.isEmpty {
            try writePage(id: mainID, name: "Camera Setup",
                          keys: ["0,0": button(cameraID: "", command: "settings", title: "ADD CAMERA", icon: "settings"),
                                 "1,0": button(cameraID: "", command: "gang", title: "GANG SETUP", icon: "gang")],
                          dials: [:], profileRoot: profileRoot, pluginBundle: pluginBundle)
            return
        }

        for (pageIndex, launcherID) in launcherIDs.enumerated() {
            var keys: [String: [String: Any]] = [:]
            let start = pageIndex * 6
            for index in start..<min(start + 6, folders.count) {
                let target = folders[index]
                let childID = freshID()
                let position = index - start
                keys["\(position % 4),\(position / 4)"] = folder(id: childID, title: target.name,
                    icon: target.cameraID == "gang" ? "gang" : "camera")
                try writeCameraFolder(id: childID, target: target,
                                      profileRoot: profileRoot, pluginBundle: pluginBundle)
            }
            if pageIndex > 0 { keys["2,1"] = navigation(next: false, title: "PREVIOUS", icon: "previous") }
            if pageIndex < launcherIDs.count - 1 { keys["3,1"] = navigation(next: true, title: "MORE CAMS", icon: "next") }
            try writePage(id: launcherID, name: name, keys: keys, dials: [:],
                          profileRoot: profileRoot, pluginBundle: pluginBundle)
        }
    }

    private static func writeCameraFolder(id: String, target: FolderTarget,
                                          profileRoot: URL, pluginBundle: URL) throws {
        let cameraID = target.cameraID
        let exposureID = freshID()
        // Keep the working profile's familiar main-page dial order.
        let mainKeys: [String: [String: Any]] = [
            "0,0": parentFolder(title: "BACK"),
            "1,0": button(cameraID: cameraID, command: "settings", title: "SETTINGS", icon: "settings"),
            "2,0": button(cameraID: cameraID, command: "gang", title: "GANG CAMS", icon: "gang"),
            "3,0": folder(id: exposureID, title: "EXPOSURE", icon: "ei"),
            "0,1": button(cameraID: cameraID, command: "playback", title: "PLAYBACK", icon: "playback"),
            "1,1": button(cameraID: cameraID, command: "live", title: "LIVE VIEW", icon: "live"),
            "2,1": button(cameraID: cameraID, command: "previousClip", title: "PREV CLIP", icon: "previousClip"),
            "3,1": button(cameraID: cameraID, command: "nextClip", title: "NEXT CLIP", icon: "nextClip")
        ]
        let mainDials: [String: [String: Any]] = [
            "0,0": dial(cameraID: cameraID, parameter: "wb", title: "WHITE BALANCE", icon: "wb"),
            "1,0": dial(cameraID: cameraID, parameter: "playback", title: "PLAYBACK SPEED", icon: "playPause"),
            "2,0": dial(cameraID: cameraID, parameter: "tint", title: "CC TINT", icon: "tint"),
            "3,0": dial(cameraID: cameraID, parameter: "shutter", title: "SHUTTER ANGLE", icon: "shutter")
        ]
        try writePage(id: id, name: "\(target.name) • Controls",
                      keys: mainKeys, dials: mainDials, profileRoot: profileRoot, pluginBundle: pluginBundle)

        let exposureKeys: [String: [String: Any]] = [
            "0,0": parentFolder(title: "CONTROLS"),
            "1,0": button(cameraID: cameraID, command: "settings", title: "SETTINGS", icon: "settings"),
            "2,0": button(cameraID: cameraID, command: "gang", title: "GANG CAMS", icon: "gang"),
            "0,1": button(cameraID: cameraID, command: "playback", title: "PLAYBACK", icon: "playback"),
            "1,1": button(cameraID: cameraID, command: "live", title: "LIVE VIEW", icon: "live")
        ]
        let exposureDials: [String: [String: Any]] = [
            "0,0": dial(cameraID: cameraID, parameter: "ei", title: "EXPOSURE INDEX", icon: "ei"),
            "1,0": dial(cameraID: cameraID, parameter: "nd", title: "ND FILTER", icon: "nd"),
            "2,0": dial(cameraID: cameraID, parameter: "fps", title: "SENSOR FPS", icon: "fps")
        ]
        try writePage(id: exposureID, name: "\(target.name) • Exposure & Frame Rate",
                      keys: exposureKeys, dials: exposureDials, profileRoot: profileRoot, pluginBundle: pluginBundle)
    }

    private static func writePage(id: String, name: String,
                                  keys: [String: [String: Any]], dials: [String: [String: Any]],
                                  profileRoot: URL, pluginBundle: URL) throws {
        let fm = FileManager.default
        let directory = profileRoot.appendingPathComponent("Profiles/\(id)", isDirectory: true)
        let images = directory.appendingPathComponent("Images", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let actions = Array(keys.values) + Array(dials.values)
        var copied: Set<String> = []
        for action in actions {
            for state in action["States"] as? [[String: Any]] ?? [] {
                guard let relative = state["Image"] as? String else { continue }
                let iconName = URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent
                if copied.insert(iconName).inserted {
                    let source = try icon(named: iconName, pluginBundle: pluginBundle)
                    try fm.copyItem(at: source, to: images.appendingPathComponent(iconName + ".png"))
                }
            }
        }
        try writeJSON([
            "Controllers": [["Actions": keys, "Type": "Keypad"], ["Actions": dials, "Type": "Encoder"]],
            "Icon": "", "Name": name
        ], to: directory.appendingPathComponent("manifest.json"))
    }

    /// Native folder schema matches Stream Deck's own installed profiles. A
    /// folder target is a sibling screen in Profiles/, not a profile switch.
    /// Stream Deck's Copy/Paste follows this child tree and remaps its IDs.
    private static func folder(id: String, title: String, icon: String) -> [String: Any] {
        [
            "ActionID": freshID().lowercased(), "LinkedTitle": true,
            "Name": "Create Folder", "Resources": NSNull(),
            "Settings": ["ProfileUUID": id.lowercased()], "State": 0,
            "States": [state(title: title, icon: icon)],
            "UUID": "com.elgato.streamdeck.profile.openchild"
        ]
    }

    private static func parentFolder(title: String) -> [String: Any] {
        [
            "ActionID": freshID().lowercased(), "LinkedTitle": true,
            "Name": "Parent Folder", "Resources": NSNull(),
            "Settings": [String: String](), "State": 0,
            "States": [state(title: title, icon: "previous")],
            "UUID": "com.elgato.streamdeck.profile.backtoparent"
        ]
    }

    private static func dial(cameraID: String, parameter: String, title: String, icon: String) -> [String: Any] {
        var action = pluginAction(cameraID: cameraID, kind: "dial", title: title, icon: icon,
                                  settings: ["parameter": parameter])
        action["Controller"] = "Encoder"
        return action
    }

    private static func button(cameraID: String, command: String, title: String, icon: String) -> [String: Any] {
        var action = pluginAction(cameraID: cameraID, kind: "button", title: title, icon: icon,
                                  settings: ["command": command])
        action["Controller"] = "Keypad"
        return action
    }

    private static func pluginAction(cameraID: String, kind: String, title: String, icon: String,
                                     settings: [String: String]) -> [String: Any] {
        var actionSettings = settings
        actionSettings["cameraID"] = cameraID
        return [
            "ActionID": freshID().lowercased(), "LinkedTitle": true, "Name": title,
            "Plugin": ["Name": "Camera Control", "UUID": pluginID, "Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.2"],
            "Resources": NSNull(), "Settings": actionSettings, "State": 0,
            "States": [state(title: title, icon: icon)], "UUID": "\(pluginID).\(kind)"
        ]
    }

    private static func navigation(next: Bool, title: String, icon: String) -> [String: Any] {
        [
            "ActionID": freshID().lowercased(), "Controller": "Keypad", "LinkedTitle": true,
            "Name": next ? "Next Page" : "Previous Page",
            "Plugin": ["Name": "Pages", "UUID": "com.elgato.streamdeck.page", "Version": "1.0"],
            "Resources": NSNull(), "Settings": [String: String](), "State": 0,
            "States": [state(title: title, icon: icon)],
            "UUID": next ? "com.elgato.streamdeck.page.next" : "com.elgato.streamdeck.page.previous"
        ]
    }

    private static func state(title: String, icon: String) -> [String: Any] {
        ["FontFamily": "Arial", "FontSize": 10, "FontStyle": "Bold", "FontUnderline": false,
         "Image": "Images/\(icon).png", "OutlineThickness": 2, "ShowTitle": true,
         "Title": title, "TitleAlignment": "bottom", "TitleColor": "#ffffff"]
    }

    private static func icon(named name: String, pluginBundle: URL) throws -> URL {
        let fm = FileManager.default
        let filename = name + ".png"
        var candidates = [
            pluginBundle.appendingPathComponent("Images/\(filename)"),
            pluginBundle.appendingPathComponent("images/\(filename)"),
            pluginBundle.appendingPathComponent("reference-icons/\(filename)"),
            pluginBundle.appendingPathComponent("assets/reference-icons/\(filename)")
        ]
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("reference-icons/\(filename)"))
            candidates.append(resources.appendingPathComponent("assets/reference-icons/\(filename)"))
            candidates.append(resources.appendingPathComponent("\(pluginID).sdPlugin/Images/\(filename)"))
        }
        // Development fallback is relative to the checked-in source file, never
        // a machine-specific Stream Deck installation or user profile path.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repository.appendingPathComponent("assets/reference-icons/\(filename)"))
        guard let match = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw BuildError.missingIcon(filename)
        }
        return match
    }

    private static func archive(directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", directory.path, destination.path]
        let error = Pipe()
        process.standardError = error
        try process.run()
        let diagnostic = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuildError.archiveFailed(String(data: diagnostic, encoding: .utf8) ?? "ditto exited with code \(process.terminationStatus)")
        }
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func freshID() -> String { UUID().uuidString }

    private static func safeFilename(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = name.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Camera Profile" : String(cleaned.prefix(120))
    }
}
