import Foundation

public struct GitHubRelease: Sendable {
    public let tagName: String
    public let version: String
    public let downloadURL: URL

    public init(tagName: String, version: String, downloadURL: URL) {
        self.tagName = tagName
        self.version = version
        self.downloadURL = downloadURL
    }
}

@MainActor
public final class UpdateChecker: ObservableObject {
    @Published public var availableUpdate: GitHubRelease?
    @Published public var isChecking = false
    @Published public var isDownloading = false
    @Published public var downloadProgress: Double = 0
    @Published public var error: String?

    private let repo: String
    private let assetName: String
    private var timer: Timer?

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    public init(repo: String = "davidgarcials/portforwarding-app", assetName: String = "PortForwarding.app.zip") {
        self.repo = repo
        self.assetName = assetName
    }

    public func startPeriodicChecks(interval: TimeInterval = 1800) {
        Task { await checkForUpdate() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdate()
            }
        }
    }

    public func stopPeriodicChecks() {
        timer?.invalidate()
        timer = nil
    }

    public func checkForUpdate() async {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            if isNewer(release.version, than: currentVersion) {
                availableUpdate = release
            } else {
                availableUpdate = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func downloadAndInstall() async {
        guard let release = availableUpdate else { return }
        isDownloading = true
        downloadProgress = 0
        error = nil

        do {
            let zipPath = try await downloadAsset(from: release.downloadURL)
            let appPath = try unzipAsset(at: zipPath)
            try replaceAndRelaunch(with: appPath)
        } catch {
            self.error = "Update failed: \(error.localizedDescription)"
            isDownloading = false
        }
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.apiError
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tagName = json?["tag_name"] as? String else {
            throw UpdateError.invalidResponse
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        guard let assets = json?["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw UpdateError.noAsset
        }

        return GitHubRelease(tagName: tagName, version: version, downloadURL: downloadURL)
    }

    // MARK: - Download

    private func downloadAsset(from url: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PortForwardingUpdate")
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipPath = tempDir.appendingPathComponent("update.zip")

        let (localURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        try FileManager.default.moveItem(at: localURL, to: zipPath)
        await MainActor.run { downloadProgress = 0.5 }
        return zipPath
    }

    // MARK: - Unzip

    private func unzipAsset(at zipPath: URL) throws -> URL {
        let extractDir = zipPath.deletingLastPathComponent().appendingPathComponent("extracted")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipPath.path, "-d", extractDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppBundle
        }

        downloadProgress = 0.8
        return appBundle
    }

    // MARK: - Replace and Relaunch

    private func replaceAndRelaunch(with newAppPath: URL) throws {
        let currentAppPath = Bundle.main.bundlePath
        let tempDir = newAppPath.deletingLastPathComponent().deletingLastPathComponent().path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", """
                sleep 1
                /bin/rm -rf "$1"
                /bin/mv "$2" "$1"
                /usr/bin/xattr -cr "$1"
                /usr/bin/open "$1"
                /bin/rm -rf "$3"
                """,
            "--", currentAppPath, newAppPath.path, tempDir,
        ]
        try process.run()

        DispatchQueue.main.async {
            exit(0)
        }
    }

    // MARK: - Version comparison

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, localParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

enum UpdateError: LocalizedError {
    case apiError
    case invalidResponse
    case noAsset
    case downloadFailed
    case unzipFailed
    case noAppBundle

    var errorDescription: String? {
        switch self {
        case .apiError: return "Failed to reach GitHub API"
        case .invalidResponse: return "Invalid response from GitHub"
        case .noAsset: return "Release asset not found"
        case .downloadFailed: return "Download failed"
        case .unzipFailed: return "Failed to extract update"
        case .noAppBundle: return "No app bundle found in update"
        }
    }
}
