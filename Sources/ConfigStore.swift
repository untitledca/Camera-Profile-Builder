import Foundation
import AppKit

enum ConfigStore {
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["CAMERA_BUILDER_CONFIG_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Camera Profile Builder", isDirectory: true)
    }()
    static let url = directory.appendingPathComponent("config.json")
    static func empty() -> BuilderConfig {
        BuilderConfig(cameras: [], selectedCameraID: "", gangIDs: [], gangEnabled: false, gangMode: "absolute")
    }
    static func load() throws -> BuilderConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return empty() }
        return try JSONDecoder().decode(BuilderConfig.self, from: Data(contentsOf: url))
    }
    static func save(_ config: BuilderConfig) throws {
        try validate(config)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
    static func validate(_ config: BuilderConfig) throws {
        guard Set(config.cameras.map(\.id)).count == config.cameras.count else { throw BuilderError.message("Camera IDs must be unique.") }
        guard Set(config.cameras.map(\.address)).count == config.cameras.count else { throw BuilderError.message("Each camera must have a different address.") }
    }
}

enum BuilderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum Installer {
    private static let streamDeckPreferencesDomain = "com.elgato.StreamDeck"
    static var streamDeckData: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.elgato.StreamDeck") }
    static var resourcePlugin: URL { Bundle.main.resourceURL!.appendingPathComponent("com.atomfilmlab.camera-control.sdPlugin") }
    static func run(_ executable: String, _ args: [String], directory: URL? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args; process.currentDirectoryURL = directory
        let pipe = Pipe(); process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BuilderError.message(String(data: data, encoding: .utf8) ?? "Command failed: \(executable)") }
    }
    static func export(_ config: BuilderConfig, to output: URL) throws -> [URL] {
        try ConfigStore.validate(config)
        return try ProfileBuilder.generate(config: config, output: output, pluginBundle: resourcePlugin)
    }

    /// App updates refresh only an already installed plugin. Existing profiles,
    /// including camera folders pasted into a user's own profiles, keep their
    /// stable action IDs and are never regenerated or removed here.
    @discardableResult
    static func refreshPluginIfNeeded() throws -> Bool {
        let fm = FileManager.default
        let plugins = streamDeckData.appendingPathComponent("Plugins", isDirectory: true)
        let installed = plugins.appendingPathComponent(resourcePlugin.lastPathComponent, isDirectory: true)
        guard fm.fileExists(atPath: installed.path) else { return false }
        try validateResourcePlugin()
        func manifest(_ directory: URL) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any],
                  object["UUID"] as? String == ProfileBuilder.pluginID,
                  object["Version"] is String else {
                throw BuilderError.message("The camera plugin manifest is invalid. Use Build & Install to repair the camera plugin.")
            }
            return object
        }
        let current = try manifest(installed)
        let bundled = try manifest(resourcePlugin)
        guard try pluginUpdateAvailable(installedVersion: current["Version"] as! String,
                                        bundledVersion: bundled["Version"] as! String) else { return false }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let backup = ConfigStore.directory.appendingPathComponent("Backups/PluginUpdate-\(stamp)", isDirectory: true)
        // Stage on the plugin volume so the final moves are atomic renames.
        let token = UUID().uuidString
        let staged = plugins.appendingPathComponent(".camera-plugin-update-\(token)", isDirectory: true)
        let previous = plugins.appendingPathComponent(".camera-plugin-previous-\(token)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: resourcePlugin, to: staged)

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck")
        let wasRunning = !running.isEmpty
        defer { if wasRunning { restartStreamDeck() } }
        for app in running {
            guard app.terminate() else {
                throw BuilderError.message("Stream Deck could not close to update the camera plugin. Quit Stream Deck, then reopen Camera Profile Builder.")
            }
        }
        for _ in 0..<100 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck").isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck").isEmpty else {
            throw BuilderError.message("Stream Deck is still running. Quit it, then reopen Camera Profile Builder to update the camera plugin.")
        }

        try fm.copyItem(at: installed, to: backup.appendingPathComponent(installed.lastPathComponent))
        var movedPrevious = false
        do {
            try fm.moveItem(at: installed, to: previous)
            movedPrevious = true
            try fm.moveItem(at: staged, to: installed)
        } catch {
            let updateError = error.localizedDescription
            if movedPrevious {
                do {
                    if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
                    try fm.moveItem(at: previous, to: installed)
                } catch {
                    throw BuilderError.message("The camera plugin update failed: \(updateError). The previous plugin could not be restored automatically: \(error.localizedDescription). Its backup is preserved at \(backup.path).")
                }
            }
            throw BuilderError.message("The camera plugin update failed and the previous plugin is unchanged: \(updateError). Backup: \(backup.path)")
        }
        // The durable backup remains available even if this temporary cleanup
        // fails. Cleanup must not turn a successful plugin update into an error.
        try? fm.removeItem(at: previous)
        return true
    }

    /// Pure version decision for startup refresh; prevents downgrades if a user
    /// opens an older app. Stream Deck plugin versions use numeric components.
    static func pluginUpdateAvailable(installedVersion: String, bundledVersion: String) throws -> Bool {
        func normalized(_ version: String) throws -> [UInt] {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
                  parts.allSatisfy({ UInt($0) != nil }) else {
                throw BuilderError.message("The camera plugin version is invalid. Use Build & Install to repair the camera plugin.")
            }
            return parts.map { UInt($0)! } + Array(repeating: 0, count: 4 - parts.count)
        }
        return try normalized(installedVersion).lexicographicallyPrecedes(normalized(bundledVersion))
    }

    // Prepare and validate everything first. The running app is stopped only
    // while taking a consistent backup and replacing our own plugin/profiles.
    static func install(_ config: BuilderConfig) throws -> [URL] {
        let fm = FileManager.default
        try validateResourcePlugin()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let exports = ConfigStore.directory.appendingPathComponent("Profiles/\(stamp)")
        let profiles = try export(config, to: exports)
        do {
            guard fm.fileExists(atPath: streamDeckData.path) else {
                throw BuilderError.message("Install and open Elgato Stream Deck, connect your Stream Deck +, then try Install again.")
            }
            let deviceID = try streamDeckPlusDeviceID()
            let staging = fm.temporaryDirectory.appendingPathComponent("CameraInstall-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let prepared = try prepareProfiles(profiles, in: staging, deviceID: deviceID)
            let allProfiles = streamDeckData.appendingPathComponent("ProfilesV3", isDirectory: true)
            let plugins = streamDeckData.appendingPathComponent("Plugins", isDirectory: true)
            let installedPlugin = plugins.appendingPathComponent(resourcePlugin.lastPathComponent, isDirectory: true)
            let tracking = ConfigStore.directory.appendingPathComponent("installed-profiles.json")
            let oldNames: [String]
            if fm.fileExists(atPath: tracking.path) {
                oldNames = try JSONDecoder().decode([String].self, from: Data(contentsOf: tracking))
            } else { oldNames = [] }

            // Register recovery before the first request to close Stream Deck.
            defer { restartStreamDeck() }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck") {
                guard app.terminate() else { throw BuilderError.message("Stream Deck could not close. Quit it and try Install again.") }
            }
            for _ in 0..<100 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck").isEmpty { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck").isEmpty else {
                throw BuilderError.message("Stream Deck is still running. Quit it, then install again.")
            }

            let backup = ConfigStore.directory.appendingPathComponent("Backups/\(stamp)", isDirectory: true)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            // Keep the complete pre-install ProfilesV3 tree, including all
            // legacy/manual profiles, for both rollback and manual recovery.
            let originals: [(source: URL, saved: URL)] = [
                (allProfiles, backup.appendingPathComponent("ProfilesV3")),
                (installedPlugin, backup.appendingPathComponent(resourcePlugin.lastPathComponent)),
                (tracking, backup.appendingPathComponent("installed-profiles.json")),
                (ConfigStore.url, backup.appendingPathComponent("config.json"))
            ]
            for original in originals where fm.fileExists(atPath: original.source.path) {
                try fm.copyItem(at: original.source, to: original.saved)
            }
            guard let preferenceSuite = UserDefaults(suiteName: streamDeckPreferencesDomain) else {
                throw BuilderError.message("The Stream Deck preferences could not be opened.")
            }
            // Stream Deck has now quit and flushed its final profile state.
            // Take a complete domain snapshot before changing device selection
            // and reconciling only our known top-level action-count delta.
            _ = preferenceSuite.synchronize()
            let originalPreferences = preferenceSuite.persistentDomain(forName: streamDeckPreferencesDomain) ?? [:]
            let preferredIndex = config.cameras.firstIndex(where: { $0.id == config.selectedCameraID }) ?? 0
            let preferredProfile = prepared.indices.contains(preferredIndex) ? prepared[preferredIndex].lastPathComponent : prepared.first?.lastPathComponent
            let activatedPreferences = try activatingProfiles(in: originalPreferences, deviceID: deviceID,
                                                              profileNames: prepared.map(\.lastPathComponent),
                                                              replacing: oldNames, preferredProfileName: preferredProfile)
            let replacedProfiles = oldNames.filter(isSafeProfileName).map { allProfiles.appendingPathComponent($0) }
                .filter(isOwnedProfile)
            let updatedPreferences = try reconcilingSessionActionCount(in: activatedPreferences,
                                                                       removing: replacedProfiles, adding: prepared)
            let preferenceBackup = try PropertyListSerialization.data(fromPropertyList: originalPreferences,
                                                                      format: .binary, options: 0)
            try preferenceBackup.write(to: backup.appendingPathComponent("StreamDeck-preferences.plist"), options: .atomic)
            var preferencesMutated = false
            // No original files have changed if backup creation fails above.
            do {
                try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
                try fm.createDirectory(at: allProfiles, withIntermediateDirectories: true)
                if fm.fileExists(atPath: installedPlugin.path) { try fm.removeItem(at: installedPlugin) }
                try fm.copyItem(at: resourcePlugin, to: installedPlugin)
                for old in replacedProfiles {
                    // The same tracked + owned set is used for both removal
                    // and the session count adjustment calculated above.
                    if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
                }
                for source in prepared {
                    try fm.copyItem(at: source, to: allProfiles.appendingPathComponent(source.lastPathComponent))
                }
                try JSONEncoder().encode(prepared.map(\.lastPathComponent)).write(to: tracking, options: .atomic)
                try ConfigStore.save(config)
                preferencesMutated = true
                preferenceSuite.set(updatedPreferences["Devices"], forKey: "Devices")
                if let report = updatedPreferences["last_app_session_report"] {
                    preferenceSuite.set(report, forKey: "last_app_session_report")
                }
                guard preferenceSuite.synchronize() else {
                    throw BuilderError.message("Stream Deck could not save the new active camera profile.")
                }
            } catch {
                let installError = error.localizedDescription
                var recoveryErrors: [String] = []
                for original in originals {
                    do {
                        if fm.fileExists(atPath: original.source.path) { try fm.removeItem(at: original.source) }
                        if fm.fileExists(atPath: original.saved.path) { try fm.copyItem(at: original.saved, to: original.source) }
                    } catch { recoveryErrors.append("\(original.source.lastPathComponent): \(error.localizedDescription)") }
                }
                if preferencesMutated {
                    preferenceSuite.setPersistentDomain(originalPreferences, forName: streamDeckPreferencesDomain)
                    if !preferenceSuite.synchronize() { recoveryErrors.append("Stream Deck preferences could not be restored.") }
                }
                if recoveryErrors.isEmpty {
                    throw BuilderError.message("Installation failed and the previous installation was restored. \(installError) Backup: \(backup.path)")
                }
                throw BuilderError.message("Installation failed: \(installError). Recovery needs attention: \(recoveryErrors.joined(separator: "; ")). The original files are preserved in \(backup.path).")
            }
            return profiles
        } catch {
            throw BuilderError.message("Profiles were exported successfully to \(exports.path). Installation did not complete: \(error.localizedDescription)")
        }
    }

    /// Pure preference transformation, shared by installation and unit checks.
    /// It leaves other devices, application associations and all unrelated
    /// preferences intact; only this device's active profile and order change.
    static func activatingProfiles(in domain: [String: Any], deviceID: String,
                                   profileNames: [String], replacing oldNames: [String],
                                   preferredProfileName: String? = nil) throws -> [String: Any] {
        guard !profileNames.isEmpty, profileNames.allSatisfy(isSafeProfileName),
              var devices = domain["Devices"] as? [String: Any],
              var device = devices[deviceID] as? [String: Any] else {
            throw BuilderError.message("Stream Deck + profile preferences are unavailable. Open Stream Deck and select your Stream Deck +, then install again.")
        }
        let newIDs = profileNames.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() }
        let oldIDs = Set(oldNames.filter(isSafeProfileName).map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased()
        })
        let newIDSet = Set(newIDs)
        var info = device["ESDProfilesInfo"] as? [String: Any] ?? [:]
        let originalOrder = (info["ESDProfilesSorting"] as? String ?? "").split(separator: ",").map(String.init)
        let remaining = originalOrder.filter { !oldIDs.contains($0.lowercased()) && !newIDSet.contains($0.lowercased()) }
        let requestedID = preferredProfileName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() }
        info["ESDProfilesPreferred"] = requestedID.flatMap { newIDSet.contains($0) ? $0 : nil } ?? newIDs[0]
        info["ESDProfilesSorting"] = (remaining + newIDs).joined(separator: ",")
        device["ESDProfilesInfo"] = info
        devices[deviceID] = device
        var result = domain
        result["Devices"] = devices
        return result
    }

    /// Stream Deck's session integrity metric counts actions on top-level and
    /// fallback screens, excluding folder descendants. Moving controls into a
    /// folder legitimately lowers that count. Apply only our replacement delta
    /// so unrelated missing user actions can still trigger its rescue warning.
    /// The caller backs up the original domain and restores it on any failure.
    static func reconcilingSessionActionCount(in domain: [String: Any], removing oldProfiles: [URL],
                                              adding newProfiles: [URL]) throws -> [String: Any] {
        guard var report = domain["last_app_session_report"] as? [String: Any],
              let previous = report["action_count"] as? Int, previous >= 0 else { return domain }
        func unique(_ profiles: [URL]) -> [URL] {
            var seen: Set<String> = []
            return profiles.filter { seen.insert($0.standardizedFileURL.path.lowercased()).inserted }
        }
        let removed = try unique(oldProfiles).filter(isOwnedProfile).reduce(0) { try $0 + topLevelActionCount(in: $1) }
        guard newProfiles.allSatisfy(isOwnedProfile) else {
            throw BuilderError.message("A replacement camera profile is missing its ownership marker.")
        }
        let added = try unique(newProfiles).reduce(0) { try $0 + topLevelActionCount(in: $1) }
        let (adjusted, overflow) = previous.addingReportingOverflow(added - removed)
        guard !overflow, adjusted >= 0 else {
            throw BuilderError.message("Stream Deck's saved action count does not match the camera profiles. Open and quit Stream Deck, then try Install again.")
        }
        report["action_count"] = adjusted
        var result = domain
        result["last_app_session_report"] = report
        return result
    }

    /// Reads only pages listed by the profile umbrella, plus its separate
    /// Default fallback. Do not recurse into native child folders here.
    static func topLevelActionCount(in profile: URL) throws -> Int {
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: profile.appendingPathComponent("manifest.json"))) as? [String: Any],
              let metadata = manifest["Pages"] as? [String: Any],
              let listed = metadata["Pages"] as? [String],
              let fallback = metadata["Default"] as? String else {
            throw BuilderError.message("A camera profile is missing its page metadata.")
        }
        var total = 0
        for id in Set((listed + [fallback]).map { $0.lowercased() }) {
            guard UUID(uuidString: id) != nil else {
                throw BuilderError.message("A camera profile contains an invalid page ID.")
            }
            let url = profile.appendingPathComponent("Profiles/\(id.uppercased())/manifest.json")
            guard let page = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let controllers = page["Controllers"] as? [[String: Any]] else {
                throw BuilderError.message("A camera profile contains an invalid page.")
            }
            for controller in controllers {
                if controller["Actions"] == nil || controller["Actions"] is NSNull { continue }
                guard let actions = controller["Actions"] as? [String: Any] else {
                    throw BuilderError.message("A camera profile contains an invalid action list.")
                }
                total += actions.count
            }
        }
        return total
    }

    private static func restartStreamDeck() {
        DispatchQueue.main.async {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.elgato.StreamDeck") {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private static func validateResourcePlugin() throws {
        let fm = FileManager.default
        let manifestURL = resourcePlugin.appendingPathComponent("manifest.json")
        guard let manifest = try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              manifest["UUID"] as? String == ProfileBuilder.pluginID,
              let code = (manifest["CodePathMac"] ?? manifest["CodePath"]) as? String,
              !code.isEmpty, !code.hasPrefix("/"), !code.split(separator: "/").contains(".."),
              fm.isExecutableFile(atPath: resourcePlugin.appendingPathComponent(code).path) else {
            throw BuilderError.message("The bundled camera plugin or its executable is missing. Reinstall Camera Profile Builder.")
        }
        let icons = ["camera", "settings", "gang", "wb", "playPause", "tint", "shutter", "ei", "nd", "fps", "live", "playback", "previousClip", "nextClip", "previous", "next"]
        for icon in icons where !fm.fileExists(atPath: resourcePlugin.appendingPathComponent("Images/\(icon).png").path) {
            throw BuilderError.message("The bundled plugin is missing the \(icon) icon. Reinstall Camera Profile Builder.")
        }
    }

    /// Resolve the actual hardware identifier, including Stream Deck versions
    /// whose PreferredDevice value contains a duplicated leading @ character.
    static func streamDeckPlusDeviceID() throws -> String {
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.elgato.StreamDeck.plist")
        let disk = (try? Data(contentsOf: preferencesURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        let domain = UserDefaults.standard.persistentDomain(forName: "com.elgato.StreamDeck") ?? disk ?? [:]
        guard let devices = domain["Devices"] as? [String: Any] else {
            throw BuilderError.message("Connect your Stream Deck + and open the Stream Deck app once, then try Install again.")
        }
        func isPlus(_ identifier: String) -> Bool {
            guard identifier.hasPrefix("@(1)["), let details = devices[identifier] as? [String: Any] else { return false }
            let name = details["DeviceName"] as? String ?? ""
            return identifier.contains("/132/") || name.localizedCaseInsensitiveContains("Stream Deck +")
        }
        if var preferred = devices["PreferredDevice"] as? String {
            if preferred.hasPrefix("@@") { preferred.removeFirst() }
            if isPlus(preferred) { return preferred }
        }
        if let identifier = devices.keys.sorted().first(where: isPlus) { return identifier }
        throw BuilderError.message("Connect your Stream Deck + and select it in the Stream Deck app, then try Install again.")
    }

    static func prepareProfiles(_ archives: [URL], in staging: URL, deviceID: String) throws -> [URL] {
        let fm = FileManager.default
        var prepared: [URL] = []
        for (index, archive) in archives.enumerated() {
            let unpacked = staging.appendingPathComponent("unpacked-\(index)", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            let roots = try fm.contentsOfDirectory(at: unpacked.appendingPathComponent("Profiles"), includingPropertiesForKeys: nil)
                .filter { isSafeProfileName($0.lastPathComponent) }
            guard roots.count == 1 else { throw BuilderError.message("An exported profile contains an invalid profile root.") }
            let root = roots[0]
            let manifestURL = root.appendingPathComponent("manifest.json")
            guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
                  var device = manifest["Device"] as? [String: Any], device["Model"] as? String == "20GBD9901",
                  var pages = manifest["Pages"] as? [String: Any], let fallback = pages["Default"] as? String,
                  let pageIDs = pages["Pages"] as? [String], let firstPage = pageIDs.first,
                  Set(pageIDs.map { $0.lowercased() }).count == pageIDs.count,
                  !pageIDs.contains(where: { $0.caseInsensitiveCompare(fallback) == .orderedSame }),
                  (pageIDs + [fallback]).allSatisfy({ UUID(uuidString: $0) != nil &&
                      fm.fileExists(atPath: root.appendingPathComponent("Profiles/\($0.uppercased())/manifest.json").path) }) else {
                throw BuilderError.message("An exported profile has invalid device or page metadata.")
            }
            device["UUID"] = deviceID
            pages["Current"] = firstPage.lowercased()
            manifest["Device"] = device
            manifest["Pages"] = pages
            manifest["InstalledByPluginUUID"] = ProfileBuilder.pluginID
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
            prepared.append(root)
        }
        return prepared
    }

    private static func isSafeProfileName(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return url.lastPathComponent == name && url.pathExtension == "sdProfile" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    private static func isOwnedProfile(_ root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return manifest["InstalledByPluginUUID"] as? String == ProfileBuilder.pluginID
    }
}
