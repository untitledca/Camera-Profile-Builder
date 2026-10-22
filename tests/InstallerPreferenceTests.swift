import Foundation

/// Pure checks only: this executable does not call Installer.install,
/// UserDefaults, NSApplication, or any camera transport.
@main
enum InstallerPreferenceTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func expectRejection(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { return }
        throw Failure(description: message)
    }

    static func main() throws {
        let pluginVersions: [(String, String, Bool)] = [
            ("2.0.0.0", "2.1.0.0", true),
            ("2.1.0.0", "2.1.0.0", false),
            ("2.1", "2.1.0.0", false),
            ("2.10.0.0", "2.9.0.0", false),
            ("2.9.0.0", "2.10.0.0", true),
            ("3.0.0.0", "2.1.0.0", false),
            ("2.1.0.1", "2.1.0.2", true)
        ]
        for (installed, bundled, expected) in pluginVersions {
            let available = try Installer.pluginUpdateAvailable(installedVersion: installed, bundledVersion: bundled)
            try expect(available == expected, "Plugin update version comparison failed for \(installed) → \(bundled).")
        }
        for malformed in ["", "2..1", "2.1.beta", "-1.0", "2.1.0.0.0", "999999999999999999999999999999"] {
            try expectRejection("An invalid installed plugin version must not trigger replacement.") {
                _ = try Installer.pluginUpdateAvailable(installedVersion: malformed, bundledVersion: "2.1.0.0")
            }
            try expectRejection("An invalid bundled plugin version must not trigger replacement.") {
                _ = try Installer.pluginUpdateAvailable(installedVersion: "2.0.0.0", bundledVersion: malformed)
            }
        }

        let deviceID = "@(1)[4057/132/TEST]"
        let otherDeviceID = "@(1)[4057/108/OTHER]"
        let trackedID = "abcdef12-1111-1111-1111-111111111111"
        let manualID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let untrackedID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let newA = "22222222-2222-2222-2222-222222222222"
        let newB = "33333333-3333-3333-3333-333333333333"
        let profileNames = [newA + ".sdProfile", newB + ".sdProfile"]
        let originalOrder = "\(trackedID.uppercased()),\(manualID),\(untrackedID),invalid"
        let otherDevice: [String: Any] = [
            "DeviceName": "Stream Deck XL", "map_dev_brightness": 43,
            "ESDProfilesInfo": ["ESDProfilesPreferred": "KEEP", "ESDProfilesSorting": "KEEP,OTHER"]
        ]
        let domain: [String: Any] = [
            "OtherPreference": Data([1, 2, 3]),
            "ActionsTree": ["example.action": ["ActionsTreeVisited": true]],
            "last_started_streamdeck_version": "7.4.2.22730",
            "Devices": [
                "PreferredDevice": "@" + deviceID,
                otherDeviceID: otherDevice,
                deviceID: [
                    "DeviceName": "Stream Deck +", "map_dev_brightness": 17, "map_dev_enabled": true,
                    "ESDProfilesInfo": [
                        "ESDProfilesPreferred": trackedID,
                        "ESDProfilesSorting": originalOrder,
                        "ESDProfilesExpanded": "EXPANSION-UNCHANGED",
                        "ESDProfilesDefault": "DEFAULT-UNCHANGED",
                        "ApplicationAssociation": ["com.example.application": "ASSOCIATION-UNCHANGED"]
                    ]
                ]
            ]
        ]
        let snapshot = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let originalCopy = try PropertyListSerialization.propertyList(from: snapshot, options: [], format: nil) as! [String: Any]

        let result = try Installer.activatingProfiles(in: domain, deviceID: deviceID,
                                                      profileNames: profileNames,
                                                      replacing: [trackedID + ".sdProfile", "invalid.sdProfile", "../" + manualID + ".sdProfile"],
                                                      preferredProfileName: newB + ".sdProfile")
        let devices = result["Devices"] as! [String: Any]
        let device = devices[deviceID] as! [String: Any]
        let info = device["ESDProfilesInfo"] as! [String: Any]
        try expect(info["ESDProfilesPreferred"] as? String == newB, "The selected camera profile must become active.")
        try expect(info["ESDProfilesSorting"] as? String == "\(manualID),\(untrackedID),invalid,\(newA),\(newB)",
                   "Only tracked valid IDs should be removed; existing order/case must survive before new IDs are appended.")
        try expect(info["ESDProfilesExpanded"] as? String == "EXPANSION-UNCHANGED", "Expanded profile state changed.")
        try expect(info["ESDProfilesDefault"] as? String == "DEFAULT-UNCHANGED", "An unrelated default preference changed.")
        try expect((info["ApplicationAssociation"] as? NSDictionary)?.isEqual(["com.example.application": "ASSOCIATION-UNCHANGED"]) == true,
                   "Application associations changed.")
        try expect(device["map_dev_brightness"] as? Int == 17 && device["map_dev_enabled"] as? Bool == true,
                   "Device settings changed.")
        try expect(devices["PreferredDevice"] as? String == "@" + deviceID, "The selected device changed.")
        try expect((devices[otherDeviceID] as? NSDictionary)?.isEqual(otherDevice) == true, "Another device's preferences changed.")
        for key in ["OtherPreference", "ActionsTree", "last_started_streamdeck_version"] {
            try expect(NSDictionary(dictionary: [key: result[key]!]).isEqual([key: domain[key]!]), "Unrelated preference \(key) changed.")
        }
        try expect(NSDictionary(dictionary: domain).isEqual(originalCopy), "The input preference domain was mutated.")

        let fallback = try Installer.activatingProfiles(in: domain, deviceID: deviceID,
                                                        profileNames: profileNames, replacing: [])
        let fallbackInfo = ((fallback["Devices"] as! [String: Any])[deviceID] as! [String: Any])["ESDProfilesInfo"] as! [String: Any]
        try expect(fallbackInfo["ESDProfilesPreferred"] as? String == newA, "Missing selection should use the first profile.")
        try expect(fallbackInfo["ESDProfilesSorting"] as? String == originalOrder + "," + newA + "," + newB,
                   "An empty tracked list must preserve all existing profile IDs.")

        let invalidSelection = try Installer.activatingProfiles(in: domain, deviceID: deviceID,
                                                                profileNames: profileNames, replacing: [],
                                                                preferredProfileName: manualID + ".sdProfile")
        let invalidSelectionInfo = ((invalidSelection["Devices"] as! [String: Any])[deviceID] as! [String: Any])["ESDProfilesInfo"] as! [String: Any]
        try expect(invalidSelectionInfo["ESDProfilesPreferred"] as? String == newA,
                   "A selection outside the new profile set should fall back to its first profile.")

        try expectRejection("A missing target device must be rejected.") {
            _ = try Installer.activatingProfiles(in: domain, deviceID: "missing", profileNames: profileNames, replacing: [])
        }
        try expectRejection("An empty profile set must be rejected.") {
            _ = try Installer.activatingProfiles(in: domain, deviceID: deviceID, profileNames: [], replacing: [])
        }
        try expectRejection("Unsafe profile filenames must be rejected.") {
            _ = try Installer.activatingProfiles(in: domain, deviceID: deviceID,
                                                 profileNames: ["../" + newA + ".sdProfile"], replacing: [])
        }
        print("Installer checks passed: plugin update/downgrade version decisions, selection, fallback, sorting, tracked IDs, preserved preferences/devices/defaults and input immutability. No live preferences were changed.")
    }
}
