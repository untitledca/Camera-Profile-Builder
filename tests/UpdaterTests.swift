import CryptoKit
import Foundation

/// Default checks use offline fixtures only. The explicit GitHub integration flag
/// downloads a real release into temporary app copies; neither mode opens any app.
@main enum UpdaterTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(description: message)
    }
    static func releaseJSON(version: String = "2.2.0") -> [String: Any] {
        let base = "https://github.com/untitledca/Camera-Profile-Builder/releases"
        let names = ["Camera_Profile_Builder_\(version).zip", "SHA256SUMS.txt", "SHA256SUMS.txt.sig"]
        return ["draft": false, "prerelease": false, "tag_name": "v\(version)", "html_url": "\(base)/tag/v\(version)",
                "body": "Camera folder updates", "assets": names.map { name in
                    ["name": name, "state": "uploaded", "size": 256,
                     "digest": "sha256:" + String(repeating: "a", count: 64),
                     "browser_download_url": "\(base)/download/v\(version)/\(name)"] as [String: Any]
                }]
    }
    static func parse(_ json: [String: Any]) throws -> UpdateRelease {
        try UpdateFeed.parse(JSONSerialization.data(withJSONObject: json))
    }
    static func changingAsset(_ source: [String: Any], index: Int = 0, key: String, value: Any) -> [String: Any] {
        var json = source, assets = json["assets"] as! [[String: Any]]
        assets[index][key] = value; json["assets"] = assets; return json
    }
    static func zip(name: String = "Camera Profile Builder.app/Contents/Info.plist", mode: Int = 0x81a4,
                    localName: String? = nil, encrypted: Bool = false, expandedSize: Int = 5) -> Data {
        var data = Data()
        func append(_ value: Int, _ bytes: Int) { for offset in 0..<bytes { data.append(UInt8((value >> (8 * offset)) & 255)) } }
        let local = Data((localName ?? name).utf8), central = Data(name.utf8)
        append(0x04034b50, 4); append(20, 2); append(encrypted ? 1 : 0, 2); append(0, 2)
        append(0, 2); append(0, 2); append(0x3610a686, 4); append(5, 4); append(expandedSize, 4)
        append(local.count, 2); append(0, 2); data.append(local); data.append(Data("hello".utf8))
        let start = data.count
        append(0x02014b50, 4); append(0x0314, 2); append(20, 2); append(encrypted ? 1 : 0, 2); append(0, 2)
        append(0, 2); append(0, 2); append(0x3610a686, 4); append(5, 4); append(expandedSize, 4)
        append(central.count, 2); append(0, 2); append(0, 2); append(0, 2); append(0, 2); append(mode << 16, 4)
        append(0, 4); data.append(central)
        let size = data.count - start
        append(0x06054b50, 4); append(0, 2); append(0, 2); append(1, 2); append(1, 2); append(size, 4); append(start, 4); append(0, 2)
        return data
    }
    static func writePlan(_ plan: UpdateInstallPlan) throws -> URL {
        let url = URL(fileURLWithPath: plan.workDirectory, isDirectory: true).appendingPathComponent("install-plan.json")
        try JSONEncoder().encode(plan).write(to: url)
        return url
    }
    static func makeSignedFixture(at app: URL, version: String, copying source: URL? = nil) throws {
        let fm = FileManager.default
        if let source { try fm.copyItem(at: source, to: app) }
        else {
            let executable = app.appendingPathComponent("Contents/MacOS/CameraProfileBuilder")
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Use an inert Mach-O executable solely to exercise app signature checks.
            // It is copied and signed inside the fixture; it is never executed.
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        }
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var plist = (NSDictionary(contentsOf: plistURL) as? [String: Any]) ?? [:]
        plist["CFBundleIdentifier"] = UpdateFeed.bundleID
        plist["CFBundleExecutable"] = "CameraProfileBuilder"
        plist["CFBundleName"] = "Camera Profile Builder"
        plist["CFBundlePackageType"] = "APPL"
        plist["CFBundleShortVersionString"] = version
        plist["CFBundleVersion"] = "1"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        _ = try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        _ = try UpdateInstaller.validateApp(app, expectedVersion: AppVersion(version))
    }
    static func transactionTest(failLaunch: Bool) throws {
        let fm = FileManager.default, temporary = fm.temporaryDirectory
        let root = temporary.appendingPathComponent("CameraUpdaterTransactionTests-\(UUID().uuidString)", isDirectory: true)
        let work = temporary.appendingPathComponent("CameraBuilder-Update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("expanded"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: work) }
        let destination = root.appendingPathComponent(UpdateFeed.appName), source = work.appendingPathComponent("expanded/" + UpdateFeed.appName)
        try makeSignedFixture(at: destination, version: "2.0.9")
        try makeSignedFixture(at: source, version: "2.1.0")
        let sentinel = root.appendingPathComponent("camera-settings-and-copied-profiles-sentinel")
        try Data("preserve me".utf8).write(to: sentinel)
        // No process has this sentinel PID; the production wait observes an already-exited parent.
        try expect(kill(Int32.max, 0) != 0, "The reserved test PID unexpectedly exists.")
        let plan = UpdateInstallPlan(source: source.path, destination: destination.path, workDirectory: work.path,
                                     oldVersion: "2.0.9", newVersion: "2.1.0", parentPID: Int32.max)
        var launches = 0
        let status = UpdateInstaller.finishUpdate(planAt: try writePlan(plan), launch: { app in
            launches += 1
            let expected = failLaunch && launches > 1 ? "2.0.9" : "2.1.0"
            _ = try UpdateInstaller.validateApp(app, expectedVersion: AppVersion(expected))
            if failLaunch && launches == 1 { throw Failure(description: "Simulated Launch Services rejection") }
        }, resultAt: root.appendingPathComponent("update-result.json"))
        try expect(status == (failLaunch ? 1 : 0), "The update transaction returned the wrong status.")
        try expect(launches == (failLaunch ? 2 : 1), "The updated/rolled-back app launch hook was not called.")
        _ = try UpdateInstaller.validateApp(destination, expectedVersion: AppVersion(failLaunch ? "2.0.9" : "2.1.0"))
        try expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve me", "An adjacent saved settings/profile sentinel changed.")
        try expect(!fm.fileExists(atPath: work.path), "The completed update work directory was not cleaned up.")
        let siblings = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        try expect(!siblings.contains(where: { $0.lastPathComponent.hasPrefix(".CameraBuilder-update-") }), "A staging app was left behind.")
        if !failLaunch {
            let backups = siblings.filter { $0.lastPathComponent.hasPrefix(".CameraBuilder-previous-") }
            try expect(backups.count == 1, "A successful update did not preserve exactly one original app backup.")
            _ = try UpdateInstaller.validateApp(backups[0], expectedVersion: AppVersion("2.0.9"))
        }
        let resultData = try Data(contentsOf: root.appendingPathComponent("update-result.json"))
        let result = try JSONSerialization.jsonObject(with: resultData) as! [String: Any]
        try expect(result["success"] as? Bool == !failLaunch, "The update result marker did not reflect the final transaction.")
    }
    static func githubInstallIntegration(copying builtApp: URL) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CameraUpdaterGitHubIntegration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent(UpdateFeed.appName)
        try makeSignedFixture(at: destination, version: "2.0.9", copying: builtApp)
        let sentinel = root.appendingPathComponent("existing-camera-settings-and-copied-profiles")
        try Data("unchanged camera/profile fixture".utf8).write(to: sentinel)
        let release = try await GitHubUpdateClient.latest()
        print("Checking actual GitHub release \(release.version): signed download and isolated 2.0.9 upgrade…")
        let prepared = try await GitHubUpdateClient.prepare(release, currentApp: destination)
        defer { try? fm.removeItem(atPath: prepared.workDirectory) }
        try expect(kill(Int32.max, 0) != 0, "The reserved test PID unexpectedly exists.")
        let plan = UpdateInstallPlan(source: prepared.source, destination: prepared.destination, workDirectory: prepared.workDirectory,
                                     oldVersion: prepared.oldVersion, newVersion: prepared.newVersion, parentPID: Int32.max)
        var launchedVersion: AppVersion?
        let result = UpdateInstaller.finishUpdate(planAt: try writePlan(plan), launch: { app in
            // This callback deliberately verifies the app instead of opening it.
            launchedVersion = try UpdateInstaller.validateApp(app, expectedVersion: release.version)
        }, resultAt: root.appendingPathComponent("result.json"))
        if result != 0 {
            let details = (try? String(contentsOf: root.appendingPathComponent("result.json"), encoding: .utf8)) ?? "No result marker"
            throw Failure(description: "Real release installation failed: \(details)")
        }
        try expect(launchedVersion == release.version, "The actual release was not installed in the isolated target.")
        try expect(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged camera/profile fixture", "The adjacent saved-settings fixture changed.")
        let backups = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".CameraBuilder-previous-") }
        try expect(backups.count == 1, "The real release update did not keep the original app backup.")
        _ = try UpdateInstaller.validateApp(backups[0], expectedVersion: AppVersion("2.0.9"))
        print("GitHub install integration passed: release \(release.version), Ed25519 signature, SHA-256, archive policy, real app signature, atomic replacement, original backup and preserved adjacent data. No apps launched and no live app/config/profile paths touched.")
    }
    static func main() async throws {
        if let flag = CommandLine.arguments.firstIndex(of: "--github-install-integration") {
            guard CommandLine.arguments.indices.contains(flag + 1) else { throw Failure(description: "Pass the built .app path after --github-install-integration.") }
            try await githubInstallIntegration(copying: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            return
        }
        try expect(try AppVersion("v2.10.0") > AppVersion("2.9.9"), "Versions must compare numerically.")
        try expect(try AppVersion("2.1") == AppVersion("2.1.0"), "Missing components normalize to zero.")
        try expect(try AppVersion("3") > AppVersion("2.999.999"), "Major versions must sort first.")
        for version in ["", "2..1", "2.1.0-beta", "2.1.0+1", "02.1.0", "2.1.0.1", "-1", "2/../../3", "99999999999999999999", " 2.1.0", "2.1.0\n"] {
            try rejects("Accepted unsafe or unstable version \(version)") { _ = try AppVersion(version) }
        }
        let valid = releaseJSON()
        let release = try parse(valid)
        try expect(release.version.description == "2.2.0", "Release version was not read.")
        try expect(release.archive.name == "Camera_Profile_Builder_2.2.0.zip", "Wrong release archive.")
        try expect(release.signature.name == "SHA256SUMS.txt.sig", "Signature asset must be mandatory.")
        for (key, value) in [("draft", true), ("prerelease", true)] {
            var json = valid; json[key] = value
            try rejects("Accepted \(key) release") { _ = try parse(json) }
        }
        for page in ["https://github.com/other/Camera-Profile-Builder/releases/tag/v2.2.0", "http://github.com/untitledca/Camera-Profile-Builder/releases/tag/v2.2.0", "https://github.com/untitledca/Camera-Profile-Builder/releases/tag/v2.2.0?redirect=x"] {
            var json = valid; json["html_url"] = page
            try rejects("Accepted wrong release page") { _ = try parse(json) }
        }
        for url in ["https://example.com/update.zip", "https://github.com.evil.test/update.zip", "https://github.com/other/Camera-Profile-Builder/releases/download/v2.2.0/Camera_Profile_Builder_2.2.0.zip", "http://github.com/untitledca/Camera-Profile-Builder/releases/download/v2.2.0/Camera_Profile_Builder_2.2.0.zip", "https://github.com/untitledca/Camera-Profile-Builder/releases/download/v2.1.0/Camera_Profile_Builder_2.2.0.zip", "https://user@github.com/untitledca/Camera-Profile-Builder/releases/download/v2.2.0/Camera_Profile_Builder_2.2.0.zip"] {
            try rejects("Accepted an untrusted asset URL") { _ = try parse(changingAsset(valid, key: "browser_download_url", value: url)) }
        }
        for size: Any in [0, -1, true, 1.5, UpdateFeed.maxArchiveSize + 1] {
            try rejects("Accepted invalid archive size") { _ = try parse(changingAsset(valid, key: "size", value: size)) }
        }
        for digest in ["sha1:" + String(repeating: "a", count: 40), "sha256:bad", "sha256:" + String(repeating: "g", count: 64)] {
            try rejects("Accepted invalid digest") { _ = try parse(changingAsset(valid, key: "digest", value: digest)) }
        }
        var unsigned = valid; unsigned["assets"] = Array((valid["assets"] as! [[String: Any]]).prefix(2))
        try rejects("A release without a signature must not be installable") { _ = try parse(unsigned) }
        var duplicates = valid; var entries = valid["assets"] as! [[String: Any]]; entries.append(entries[0]); duplicates["assets"] = entries
        try rejects("Duplicate archive entries must be rejected") { _ = try parse(duplicates) }

        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let publicKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let archiveName = "Camera_Profile_Builder_2.2.0.zip"
        let contents = Data("trusted release".utf8)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let manifest = Data("\(digest)  \(archiveName)\n".utf8)
        let signature = Data((try signingKey.signature(for: manifest)).base64EncodedString().utf8)
        let expected = try UpdateIntegrity.authenticatedChecksum(manifest: manifest, signature: signature, assetName: archiveName, publicKeyBase64: publicKey)
        try expect(expected == digest, "A valid Ed25519 manifest was rejected.")
        try rejects("Tampered manifest was accepted") {
            _ = try UpdateIntegrity.authenticatedChecksum(manifest: manifest + Data(" ".utf8), signature: signature, assetName: archiveName, publicKeyBase64: publicKey)
        }
        try rejects("Wrong signing key was accepted") {
            _ = try UpdateIntegrity.authenticatedChecksum(manifest: manifest, signature: signature, assetName: archiveName, publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        }
        try rejects("Malformed signature was accepted") {
            _ = try UpdateIntegrity.authenticatedChecksum(manifest: manifest, signature: Data("invalid".utf8), assetName: archiveName, publicKeyBase64: publicKey)
        }
        let doubled = manifest + manifest
        try rejects("A duplicated signed archive checksum was accepted") {
            _ = try UpdateIntegrity.authenticatedChecksum(manifest: doubled, signature: Data((try signingKey.signature(for: doubled)).base64EncodedString().utf8), assetName: archiveName, publicKeyBase64: publicKey)
        }
        try rejects("A signed manifest for another archive was accepted") {
            _ = try UpdateIntegrity.authenticatedChecksum(manifest: manifest, signature: signature, assetName: "Other.zip", publicKeyBase64: publicKey)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("update.zip"); try contents.write(to: file)
        try UpdateIntegrity.verify(file: file, expected: expected, githubDigest: digest)
        try rejects("Corrupted download was accepted") { try UpdateIntegrity.verify(file: file, expected: String(repeating: "a", count: 64)) }
        try rejects("Contradictory GitHub digest was accepted") { try UpdateIntegrity.verify(file: file, expected: expected, githubDigest: String(repeating: "a", count: 64)) }

        try UpdateArchivePolicy.validate(zip())
        for path in ["../Camera Profile Builder.app/Contents/Info.plist", "Camera Profile Builder.app/../../escape", "/Camera Profile Builder.app/Contents/Info.plist", "Other.app/Contents/Info.plist", "Camera Profile Builder.app//Contents/Info.plist", "Camera Profile Builder.app/./Contents/Info.plist", "Camera Profile Builder.app/Contents\\escape", "Camera Profile Builder.app/Contents/line\nname"] {
            try rejects("Unsafe ZIP entry was accepted: \(path)") { try UpdateArchivePolicy.validate(zip(name: path)) }
        }
        try rejects("ZIP symlinks must be rejected") { try UpdateArchivePolicy.validate(zip(mode: 0xa1ff)) }
        try rejects("Encrypted ZIPs must be rejected") { try UpdateArchivePolicy.validate(zip(encrypted: true)) }
        try rejects("Oversized expanded ZIPs must be rejected") { try UpdateArchivePolicy.validate(zip(expandedSize: 601 * 1024 * 1024)) }
        try rejects("Different local and central ZIP names must be rejected") { try UpdateArchivePolicy.validate(zip(localName: "Camera Profile Builder.app/Contents/Badx.plist")) }
        try rejects("Truncated ZIPs must be rejected") { try UpdateArchivePolicy.validate(zip().dropLast()) }
        try rejects("ZIPs with trailing payloads must be rejected") { try UpdateArchivePolicy.validate(zip() + Data([1])) }
        try rejects("A disk image installation destination must be rejected") { try UpdateInstaller.checkDestination(URL(fileURLWithPath: "/Volumes/Camera Profile Builder/Camera Profile Builder.app")) }
        try transactionTest(failLaunch: false)
        try transactionTest(failLaunch: true)
        print("Updater checks passed: stable versions, pinned GitHub assets, Ed25519 authentication/tampering, SHA-256 corruption, safe ZIPs, isolated signed-app replacement/backup and failed-launch rollback. No network, app launches or live app/config/profile changes.")
    }
}
