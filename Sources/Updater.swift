import AppKit
import Combine
import CryptoKit
import Foundation

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Stable releases only. Numeric comparison avoids treating 2.10 as older than 2.9.
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]
    init(_ input: String) throws {
        var text = input
        if text.first == "v" { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), pieces.allSatisfy({ piece in
            !piece.isEmpty && piece.utf8.allSatisfy({ (48...57).contains($0) }) &&
            (piece.count == 1 || piece.first != "0") && (Int(piece) ?? -1) >= 0 && (Int(piece) ?? Int.max) <= 999_999
        }) else { throw UpdateError.message("The release has an unsupported version number.") }
        components = pieces.map { Int($0)! } + Array(repeating: 0, count: 3 - pieces.count)
    }
    var description: String { components.map(String.init).joined(separator: ".") }
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct UpdateAsset: Equatable {
    let name: String
    let url: URL
    let size: Int
    let digest: String?
}

struct UpdateRelease: Equatable {
    let version: AppVersion
    let tag: String
    let pageURL: URL
    let notes: String
    let archive: UpdateAsset
    let checksums: UpdateAsset
    let signature: UpdateAsset
}

enum UpdateFeed {
    static let owner = "untitledca"
    static let repository = "Camera-Profile-Builder"
    static let bundleID = "com.atomfilmlab.camera-profile-builder"
    static let appName = "Camera Profile Builder.app"
    static let repositoryURL = URL(string: "https://github.com/\(owner)/\(repository)")!
    static let latestURL = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    static let maxArchiveSize = 300 * 1024 * 1024

    static func validReleaseURL(_ url: URL, tag: String, asset: String? = nil) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let expected = asset.map { "/\(owner)/\(repository)/releases/download/\(tag)/\($0)" }
            ?? "/\(owner)/\(repository)/releases/tag/\(tag)"
        return url.path == expected
    }

    static func parse(_ data: Data) throws -> UpdateRelease {
        guard data.count <= 2 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let draft = json["draft"] as? Bool, !draft,
              let prerelease = json["prerelease"] as? Bool, !prerelease,
              let tag = json["tag_name"] as? String,
              let page = json["html_url"] as? String, let pageURL = URL(string: page),
              validReleaseURL(pageURL, tag: tag),
              let assets = json["assets"] as? [[String: Any]] else {
            throw UpdateError.message("GitHub did not return a valid stable Camera Profile Builder release.")
        }
        let version = try AppVersion(tag)
        // A normalized tag prevents ambiguous asset names and path components.
        guard tag == "v\(version)" || tag == version.description else {
            throw UpdateError.message("The release tag is not a supported stable version.")
        }
        func asset(_ name: String, maximum: Int) throws -> UpdateAsset {
            let matches = assets.filter { $0["name"] as? String == name }
            guard matches.count == 1, let value = matches.first,
                  value["state"] as? String == "uploaded",
                  let rawSize = value["size"] as? NSNumber, CFGetTypeID(rawSize) != CFBooleanGetTypeID(),
                  rawSize.doubleValue == Double(rawSize.intValue), (1...maximum).contains(rawSize.intValue),
                  let rawURL = value["browser_download_url"] as? String, let url = URL(string: rawURL),
                  validReleaseURL(url, tag: tag, asset: name) else {
                throw UpdateError.message("The release is missing a valid \(name) download. Open its GitHub release page to install manually.")
            }
            var digest: String?
            if let raw = value["digest"] as? String {
                guard raw.hasPrefix("sha256:"), UpdateIntegrity.isSHA256(String(raw.dropFirst(7))) else {
                    throw UpdateError.message("GitHub returned an invalid SHA-256 digest.")
                }
                digest = String(raw.dropFirst(7)).lowercased()
            }
            return UpdateAsset(name: name, url: url, size: rawSize.intValue, digest: digest)
        }
        return UpdateRelease(version: version, tag: tag, pageURL: pageURL,
                             notes: String((json["body"] as? String ?? "").prefix(16_000)),
                             archive: try asset("Camera_Profile_Builder_\(version).zip", maximum: maxArchiveSize),
                             checksums: try asset("SHA256SUMS.txt", maximum: 64 * 1024),
                             signature: try asset("SHA256SUMS.txt.sig", maximum: 1024))
    }
}

enum UpdateIntegrity {
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    /// The signing key authenticates the manifest independently of the GitHub account.
    static func authenticatedChecksum(manifest: Data, signature: Data, assetName: String,
                                      publicKeyBase64: String) throws -> String {
        guard manifest.count <= 64 * 1024, signature.count <= 1024,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signatureText = String(data: signature, encoding: .utf8),
              let signatureData = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              key.isValidSignature(signatureData, for: manifest),
              let text = String(data: manifest, encoding: .utf8) else {
            throw UpdateError.message("The update signature is invalid. Nothing was installed. Download a fresh release or contact the developer.")
        }
        var matching: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, isSHA256(String(parts[0])) else {
                throw UpdateError.message("The signed update checksum file is malformed.")
            }
            var name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name == assetName { matching.append(String(parts[0]).lowercased()) }
        }
        guard matching.count == 1 else { throw UpdateError.message("The signed checksum file must identify this app archive exactly once.") }
        return matching[0]
    }
    static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verify(file: URL, expected: String, githubDigest: String? = nil) throws {
        guard isSHA256(expected) else { throw UpdateError.message("The expected update checksum is invalid.") }
        let actual = try sha256(file: file)
        guard actual == expected.lowercased(), githubDigest == nil || actual == githubDigest!.lowercased() else {
            throw UpdateError.message("The update download failed its SHA-256 check. Nothing was installed. Try downloading again.")
        }
    }
}

/// Reject traversal, symlinks, unexpected roots and oversized ZIPs before extraction.
/// We ship small, ordinary ZIPs; ZIP64 and split/encrypted archives are unnecessary.
enum UpdateArchivePolicy {
    static func validate(_ data: Data) throws {
        func fail() -> UpdateError { .message("The update archive is not a safe Camera Profile Builder app archive.") }
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, count <= 4, offset <= data.count - count else { throw fail() }
            return (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) }
        }
        guard data.count >= 22, data.count <= UpdateFeed.maxArchiveSize else { throw fail() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try number(offset, 4) == 0x06054b50,
               try offset + 22 + number(offset + 20, 2) == data.count { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw fail() }
        let count = try number(end + 10, 2), size = try number(end + 12, 4), start = try number(end + 16, 4)
        guard (1...20_000).contains(count), try number(end + 8, 2) == count, start + size == end else { throw fail() }
        var cursor = start, expanded = 0, names = Set<String>(), appEntries = 0
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw fail() }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let nameLength = try number(cursor + 28, 2), extra = try number(cursor + 30, 2), comment = try number(cursor + 32, 2)
            let attributes = try number(cursor + 38, 4), local = try number(cursor + 42, 4)
            let fileType = (attributes >> 16) & 0xf000
            expanded += try number(cursor + 24, 4)
            guard flags & 1 == 0, [0, 8].contains(method), [0, 0x4000, 0x8000].contains(fileType),
                  expanded <= 600 * 1024 * 1024, nameLength > 0, cursor + 46 + nameLength + extra + comment <= end,
                  let name = String(data: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), encoding: .utf8),
                  !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !name.hasPrefix("/"), names.insert(name).inserted else { throw fail() }
            let pieces = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !pieces.contains(".."), !pieces.contains("."), !pieces.dropLast().contains("") else { throw fail() }
            if name == UpdateFeed.appName || name.hasPrefix(UpdateFeed.appName + "/") { appEntries += 1 }
            else if name != "__MACOSX/" && !name.hasPrefix("__MACOSX/" + UpdateFeed.appName + "/") &&
                        name != "__MACOSX/._" + UpdateFeed.appName { throw fail() }
            guard try number(local, 4) == 0x04034b50, try number(local + 26, 2) == nameLength,
                  local + 30 + nameLength <= start,
                  data.subdata(in: (local + 30)..<(local + 30 + nameLength)) == Data(name.utf8) else { throw fail() }
            cursor += 46 + nameLength + extra + comment
        }
        guard cursor == end, appEntries > 0 else { throw fail() }
    }
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static func allowed(_ url: URL) -> Bool {
        let hosts = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
        return url.scheme == "https" && hosts.contains(url.host?.lowercased() ?? "") &&
            url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allowed) == true ? request : nil)
    }
}

enum GitHubUpdateClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
    }()
    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Camera-Profile-Builder", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, let url = http.url, UpdateRedirectPolicy.allowed(url) else {
            throw UpdateError.message("The update server returned an untrusted redirect.")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.message("GitHub's update limit was reached. Try again later.") }
            if http.statusCode == 404 { throw UpdateError.message("No public update release is available yet.") }
            throw UpdateError.message("GitHub could not provide the update (HTTP \(http.statusCode)). Try again later.")
        }
    }
    static func latest() async throws -> UpdateRelease {
        let (data, response) = try await session.data(for: request(UpdateFeed.latestURL))
        try validate(response); return try UpdateFeed.parse(data)
    }
    private static func smallAsset(_ asset: UpdateAsset) async throws -> Data {
        let (data, response) = try await session.data(for: request(asset.url)); try validate(response)
        guard data.count == asset.size else { throw UpdateError.message("The downloaded \(asset.name) size does not match its release metadata.") }
        if let digest = asset.digest {
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw UpdateError.message("A release verification file failed its GitHub checksum.")
            }
        }
        return data
    }
    static func prepare(_ release: UpdateRelease, currentApp: URL) async throws -> UpdateInstallPlan {
        let manifest = try await smallAsset(release.checksums)
        let signature = try await smallAsset(release.signature)
        let expected = try UpdateIntegrity.authenticatedChecksum(manifest: manifest, signature: signature,
                                                                assetName: release.archive.name, publicKeyBase64: UpdatePublicKey.base64)
        let (temporary, response) = try await session.download(for: request(release.archive.url))
        try validate(response)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("CameraBuilder-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let archive = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: temporary, to: archive)
            return try await Task.detached(priority: .userInitiated) {
                guard (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue == release.archive.size else {
                    throw UpdateError.message("The update archive size does not match the release.")
                }
                try UpdateIntegrity.verify(file: archive, expected: expected, githubDigest: release.archive.digest)
                try UpdateArchivePolicy.validate(Data(contentsOf: archive, options: .mappedIfSafe))
                let expanded = work.appendingPathComponent("expanded", isDirectory: true)
                try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
                _ = try UpdateInstaller.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
                let app = expanded.appendingPathComponent(UpdateFeed.appName, isDirectory: true)
                let oldVersion = try UpdateInstaller.validateApp(currentApp)
                _ = try UpdateInstaller.validateApp(app, expectedVersion: release.version, expectedTeam: UpdateInstaller.teamID(currentApp))
                guard release.version > oldVersion else { throw UpdateError.message("This update is not newer than the installed app.") }
                return UpdateInstallPlan(source: app.path, destination: currentApp.path, workDirectory: work.path,
                                         oldVersion: oldVersion.description, newVersion: release.version.description,
                                         parentPID: ProcessInfo.processInfo.processIdentifier)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }
}

struct UpdateInstallPlan: Codable {
    let source: String
    let destination: String
    let workDirectory: String
    let oldVersion: String
    let newVersion: String
    let parentPID: Int32
}

enum UpdateInstaller {
    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Camera Profile Builder/Updates", isDirectory: true)
    }
    static var resultURL: URL { stateDirectory.appendingPathComponent("last-result.json") }
    static func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UpdateError.message("Update verification or installation failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))") }
        return output
    }
    static func teamID(_ app: URL) -> String? {
        guard let output = try? run("/usr/bin/codesign", ["-d", "--verbose=4", app.path]) else { return nil }
        return output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }.flatMap { $0 == "not set" ? nil : $0 }
    }
    @discardableResult static func validateApp(_ app: URL, expectedVersion: AppVersion? = nil, expectedTeam: String? = nil) throws -> AppVersion {
        guard app.pathExtension == "app", app.isFileURL,
              let resourceValues = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true,
              let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == UpdateFeed.bundleID,
              plist["CFBundleExecutable"] as? String == "CameraProfileBuilder",
              let rawVersion = plist["CFBundleShortVersionString"] as? String else {
            throw UpdateError.message("The update does not contain the expected Camera Profile Builder app.")
        }
        let version = try AppVersion(rawVersion)
        guard expectedVersion == nil || expectedVersion == version else { throw UpdateError.message("The app version does not match the GitHub release.") }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", "-R=identifier \"\(UpdateFeed.bundleID)\"", app.path])
        if let expectedTeam, teamID(app) != expectedTeam { throw UpdateError.message("The update was signed by a different Apple developer team.") }
        return version
    }
    static func checkDestination(_ app: URL) throws {
        guard app.isFileURL, app.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: app.path),
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
              !app.path.contains("/AppTranslocation/"), !app.path.hasPrefix("/Volumes/") else {
            throw UpdateError.message("Copy Camera Profile Builder to a writable Applications folder and open that copy before installing an update. The app cannot update itself from a disk image.")
        }
    }
    static func begin(_ plan: UpdateInstallPlan) throws {
        let destination = URL(fileURLWithPath: plan.destination, isDirectory: true)
        try checkDestination(destination)
        let work = URL(fileURLWithPath: plan.workDirectory, isDirectory: true)
        let planURL = work.appendingPathComponent("install-plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planURL.path)
        // Keep the old app as a backup while this child executes its mapped binary.
        // No shell, privilege escalation, or Gatekeeper/quarantine changes are used.
        let helper = Process()
        helper.executableURL = destination.appendingPathComponent("Contents/MacOS/CameraProfileBuilder")
        helper.arguments = ["--finish-app-update", planURL.path]
        helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
    private static func saveResult(success: Bool, message: String, at result: URL) {
        try? FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: ["success": success, "message": message]) { try? data.write(to: result, options: .atomic) }
    }
    /// Called only by the dedicated CLI branch; never enters NSApplication.run().
    /// The explicit launcher/result dependencies let integration tests run the same
    /// file transaction in an isolated directory without opening an app or writing live state.
    static func finishUpdate(planAt planURL: URL,
                             launch: (URL) throws -> Void = { app in _ = try run("/usr/bin/open", ["-n", app.path, "--args", "--app-updated"]) },
                             resultAt result: URL = resultURL) -> Int32 {
        var destination: URL?, backup: URL?, staged: URL?, work: URL?
        var replaced = false, movedOld = false
        do {
            let plan = try JSONDecoder().decode(UpdateInstallPlan.self, from: Data(contentsOf: planURL))
            let target = URL(fileURLWithPath: plan.destination, isDirectory: true).standardizedFileURL
            let source = URL(fileURLWithPath: plan.source, isDirectory: true).standardizedFileURL
            let directory = URL(fileURLWithPath: plan.workDirectory, isDirectory: true).standardizedFileURL
            guard plan.parentPID > 1, plan.parentPID != ProcessInfo.processInfo.processIdentifier,
                  directory.lastPathComponent.hasPrefix("CameraBuilder-Update-"),
                  directory.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
                  planURL.standardizedFileURL == directory.appendingPathComponent("install-plan.json"),
                  source == directory.appendingPathComponent("expanded/" + UpdateFeed.appName),
                  target != source else { throw UpdateError.message("The update install plan is invalid.") }
            destination = target; work = directory
            try checkDestination(target)
            let previousVersion = try validateApp(target, expectedVersion: AppVersion(plan.oldVersion))
            let nextVersion = try AppVersion(plan.newVersion)
            guard nextVersion > previousVersion else { throw UpdateError.message("An older app cannot replace the current app.") }
            _ = try validateApp(source, expectedVersion: nextVersion, expectedTeam: teamID(target))
            let parent = target.deletingLastPathComponent()
            let stage = parent.appendingPathComponent(".CameraBuilder-update-\(UUID().uuidString).app", isDirectory: true)
            let old = parent.appendingPathComponent(".CameraBuilder-previous-\(UUID().uuidString).app", isDirectory: true)
            staged = stage; backup = old
            try FileManager.default.copyItem(at: source, to: stage)
            _ = try validateApp(stage, expectedVersion: nextVersion, expectedTeam: teamID(target))
            // The installer waits outside the UI process. A failed/denied quit leaves the app untouched.
            let deadline = Date().addingTimeInterval(120)
            while kill(plan.parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            guard kill(plan.parentPID, 0) != 0 else { throw UpdateError.message("The app did not quit in time. No update was installed.") }
            // Revalidate immediately before the two same-volume renames.
            _ = try validateApp(target, expectedVersion: previousVersion)
            try FileManager.default.moveItem(at: target, to: old); movedOld = true
            try FileManager.default.moveItem(at: stage, to: target); replaced = true
            _ = try validateApp(target, expectedVersion: nextVersion, expectedTeam: teamID(old))
            saveResult(success: true, message: "Updated to \(nextVersion). Your camera configuration and Stream Deck profiles were kept.", at: result)
            try launch(target)
            try? FileManager.default.removeItem(at: directory)
            return 0
        } catch {
            var recoveryNote = ""
            if let destination, let backup, movedOld {
                do {
                    if replaced, FileManager.default.fileExists(atPath: destination.path) {
                        // Move the failed replacement aside before restoring; never discard the only old copy.
                        let failed = destination.deletingLastPathComponent().appendingPathComponent(".CameraBuilder-failed-\(UUID().uuidString).app")
                        try FileManager.default.moveItem(at: destination, to: failed)
                    }
                    if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: backup, to: destination) }
                    else { throw UpdateError.message("The original app's location is occupied.") }
                } catch { recoveryNote = " The previous app is preserved at \(backup.path). Restore it there manually if needed." }
            }
            if let staged { try? FileManager.default.removeItem(at: staged) }
            if let work { try? FileManager.default.removeItem(at: work) }
            saveResult(success: false, message: "The update did not finish: \(error.localizedDescription)\(recoveryNote)", at: result)
            if let destination, FileManager.default.fileExists(atPath: destination.path) { try? launch(destination) }
            return 1
        }
    }
}

@MainActor final class AppUpdater: ObservableObject {
    @Published var checking = false
    @Published var installing = false
    @Published var status = "Check GitHub for a newer build."
    @Published var error = ""
    @Published var availableRelease: UpdateRelease?
    @Published private(set) var relaunchReady = false
    private var relaunchScheduled = false
    @Published var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: "AutomaticallyCheckForUpdates") }
    }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.2" }
    init() {
        automaticChecks = UserDefaults.standard.bool(forKey: "AutomaticallyCheckForUpdates")
        if let data = try? Data(contentsOf: UpdateInstaller.resultURL),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = result["message"] as? String {
            status = message
            if result["success"] as? Bool == false { error = message }
            try? FileManager.default.removeItem(at: UpdateInstaller.resultURL)
        }
    }
    func checkOnLaunch() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.object(forKey: "LastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 6 * 60 * 60 { checkForUpdates(manual: false) }
    }
    func checkForUpdates(manual: Bool = true) {
        guard !checking, !installing else { return }
        checking = true; error = ""; status = "Checking GitHub releases…"
        Task {
            defer { checking = false }
            do {
                let release = try await GitHubUpdateClient.latest()
                UserDefaults.standard.set(Date(), forKey: "LastUpdateCheck")
                if release.version > (try AppVersion(currentVersion)) {
                    availableRelease = release; status = "Version \(release.version) is available. Install Update downloads it and relaunches the app."
                } else { availableRelease = nil; status = "Camera Profile Builder \(currentVersion) is up to date." }
            } catch {
                status = "Updates could not be checked."
                if manual { self.error = error.localizedDescription }
            }
        }
    }
    func installAvailableUpdate() {
        guard let release = availableRelease, !checking, !installing else { return }
        do { try UpdateInstaller.checkDestination(Bundle.main.bundleURL) }
        catch { self.error = error.localizedDescription; return }
        installing = true; error = ""; status = "Downloading and verifying the signed update…"
        Task {
            do {
                let plan = try await GitHubUpdateClient.prepare(release, currentApp: Bundle.main.bundleURL)
                do { try UpdateInstaller.begin(plan) }
                catch { try? FileManager.default.removeItem(atPath: plan.workDirectory); throw error }
                status = "Installing \(release.version). The app will reopen shortly…"
                // A presented SwiftUI sheet can prevent AppKit termination.
                // The view dismisses it and calls completeRelaunch from onDismiss.
                relaunchReady = true
            } catch { installing = false; status = "The update was not installed."; self.error = error.localizedDescription }
        }
    }
    func completeRelaunch() {
        guard relaunchReady, !relaunchScheduled else { return }
        relaunchScheduled = true
        RunLoop.main.perform(inModes: [.common]) { NSApplication.shared.terminate(nil) }
    }
}
