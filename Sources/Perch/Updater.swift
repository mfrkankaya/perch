import AppKit
import Foundation

/// Lightweight, dependency-free "check for updates" helper.
///
/// Perch stays network-idle unless the user asks (see README's privacy note), so this
/// only contacts GitHub when explicitly triggered. It never installs anything silently:
/// the user presses "Check", confirms "Download & Install", and the app replaces itself
/// with the signed release asset, then restarts.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let htmlURL: URL
        let downloadURL: URL
        let notes: String?
        /// True when the download URL is just the release page (no .zip asset found).
        var isDirectDownload: Bool { downloadURL != htmlURL }
    }

    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var pendingRelease: Release?
    @Published private(set) var latestVersion: String?
    @Published private(set) var latestURL: URL?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var statusText: String = ""

    /// Set just before terminating for an update restart so
    /// `applicationWillTerminate` keeps lid-sleep mode across the relaunch.
    private(set) var isRelaunchingForUpdate = false

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var repository: (owner: String, name: String) { ("mfrkankaya", "perch") }

    // MARK: - Opt-in automatic checks (at most once a day, silent)

    var autoCheckEnabled: Bool { UserDefaults.standard.bool(forKey: Keys.autoCheckUpdates) }
    static let autoCheckInterval: TimeInterval = 24 * 3600
    private var autoCheckTimer: Timer?

    /// Starts (or stops) the opt-in daily check. Called at launch and whenever
    /// the setting changes. Does nothing unless the user enabled it.
    func scheduleAutomaticChecks() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
        guard autoCheckEnabled else { return }
        checkIfStaleForAuto()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfStaleForAuto() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        autoCheckTimer = t
    }

    func checkIfStaleForAuto() {
        guard autoCheckEnabled, !isChecking, !isInstalling else { return }
        let last = UserDefaults.standard.double(forKey: Keys.lastUpdateCheck)
        if last <= 0 || Date().timeIntervalSince1970 - last >= Self.autoCheckInterval {
            check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool = true) {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        if statusText.isEmpty { statusText = L("Yükleniyor…") }
        Task { [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }
            do {
                let release = try await self.fetchLatest()
                self.lastChecked = Date()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastUpdateCheck)
                self.latestVersion = release.version
                self.latestURL = release.downloadURL
                if release.version.versionCompare(self.currentVersion) == .orderedDescending {
                    self.pendingRelease = release
                    self.statusText = L("Yeni sürüm: %@", release.version)
                    if userInitiated { self.showUpdateAvailable(release) }
                } else {
                    self.pendingRelease = nil
                    self.statusText = L("Güncel")
                    if userInitiated { self.showUpToDate() }
                }
            } catch {
                self.statusText = L("Güncellemeler kontrol edilemedi")
                if userInitiated { self.showFailure(error) }
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        let (owner, name) = (repository.owner, repository.name)
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Perch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let rawTag = (json["tag_name"] as? String) ?? ""
        let version = rawTag.trimmingCharacters(in: .whitespaces).trimmingPrefix("v")
        guard !version.isEmpty, let html = json["html_url"] as? String, let htmlURL = URL(string: html) else {
            throw URLError(.cannotParseResponse)
        }

        let assets = json["assets"] as? [[String: Any]]
        let zipAsset = assets?.first { name in
            (name["name"] as? String)?.lowercased().hasSuffix(".zip") == true
        }
        let downloadURL: URL
        if let s = zipAsset?["browser_download_url"] as? String, let u = URL(string: s) {
            downloadURL = u
        } else {
            downloadURL = htmlURL
        }

        return Release(
            version: version,
            htmlURL: htmlURL,
            downloadURL: downloadURL,
            notes: json["body"] as? String
        )
    }

    // MARK: - Update dialog

    private func showUpdateAvailable(_ release: Release) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Yeni sürüm mevcut")
        var info = L("Perch %@ mevcut (sizde %@).", release.version, currentVersion)
        if let notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            info += "\n\n" + String(notes.prefix(600))
        }
        alert.informativeText = info
        if release.isDirectDownload {
            alert.addButton(withTitle: L("İndir ve kur"))
        } else {
            alert.addButton(withTitle: L("İndir"))
        }
        alert.addButton(withTitle: L("Sürüm notları"))
        alert.addButton(withTitle: L("Daha sonra"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if release.isDirectDownload {
                downloadAndInstall(release)
            } else {
                NSWorkspace.shared.open(release.downloadURL)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Perch güncel")
        alert.informativeText = L("Kurulu sürüm: %@", currentVersion)
        alert.addButton(withTitle: L("Tamam"))
        alert.runModal()
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Güncellemeler kontrol edilemedi")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("Tamam"))
        alert.runModal()
    }

    // MARK: - Download, install, relaunch

    func downloadAndInstall(_ release: Release) {
        guard !isInstalling else { return }
        isInstalling = true
        statusText = L("İndiriliyor…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let newApp = try await self.downloadAndExtract(release: release)
                try self.validate(newApp: newApp, release: release)
                self.statusText = L("Kuruluyor…")
                try self.installAndRelaunch(newApp: newApp)
                // installAndRelaunch terminates the app; if we are still here it launched a helper.
                self.statusText = L("Yeniden başlatılıyor…")
            } catch is CancellationError {
                self.isInstalling = false
                self.statusText = L("Yeni sürüm: %@", release.version)
            } catch {
                self.isInstalling = false
                self.statusText = L("Güncelleme kurulamadı")
                self.showFailure(error)
            }
        }
    }

    /// Downloads the release .zip and returns the extracted `Perch.app` URL.
    private func downloadAndExtract(release: Release) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-update-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zipURL = tmp.appendingPathComponent("Perch-\(release.version).zip")
        let expandDir = tmp.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expandDir, withIntermediateDirectories: true)

        let (dlURL, response) = try await URLSession.shared.download(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // Move out of the session's temp location before it gets cleaned up.
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try FileManager.default.moveItem(at: dlURL, to: zipURL)

        let st = Shell.run("/usr/bin/ditto", ["-xk", zipURL.path, expandDir.path])
        guard st.status == 0 else { throw UpdaterError.extractFailed }
        guard let appURL = Self.findApp(in: expandDir) else { throw UpdaterError.appNotFound }
        return appURL
    }

    private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        // Fast path: top-level Perch.app.
        let direct = dir.appendingPathComponent("Perch.app")
        if fm.fileExists(atPath: direct.path) { return direct }
        // Any top-level *.app.
        if let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           let app = top.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        // One level deeper (some zips wrap the app in a folder).
        if let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let nested = sub.appendingPathComponent("Perch.app")
                if fm.fileExists(atPath: nested.path) { return nested }
                if let inner = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
                   let app = inner.first(where: { $0.pathExtension == "app" }) {
                    return app
                }
            }
        }
        return nil
    }

    private func validate(newApp: URL, release: Release) throws {
        let currentID = Bundle.main.bundleIdentifier
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let newID = info?["CFBundleIdentifier"] as? String
        let newVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        guard newID == currentID else { throw UpdaterError.identifierMismatch }
        guard newVersion.versionCompare(currentVersion) == .orderedDescending else {
            throw UpdaterError.notNewer
        }
        // Must at least match the release we advertised (tolerate build-number-only drift).
        if !release.version.isEmpty, newVersion != release.version,
           newVersion.versionCompare(release.version) == .orderedAscending {
            throw UpdaterError.notNewer
        }
    }

    /// Replaces the running app with `newApp` and restarts.
    ///
    /// The relaunch-safe flow:
    /// 1. Persist awake/lid state so the new process can pick it up.
    /// 2. If the install location is writable, hand off to a helper script that waits
    ///    for this process to exit, swaps the bundle, and re-opens it — then terminate.
    /// 3. Otherwise (e.g. a root-owned /Applications) ask for admin once, replace live,
    ///    re-open, and terminate.
    private func installAndRelaunch(newApp: URL) throws {
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else { throw UpdaterError.installFailed }

        persistStateForRelaunch()
        isRelaunchingForUpdate = true

        let fm = FileManager.default
        let parent = currentApp.deletingLastPathComponent().path
        let stagingDir = newApp.deletingLastPathComponent().deletingLastPathComponent().path

        if fm.isWritableFile(atPath: parent) {
            let pid = ProcessInfo.processInfo.processIdentifier
            let scriptURL = URL(fileURLWithPath: stagingDir).appendingPathComponent("install-and-relaunch.sh")
            let script = """
            #!/bin/sh
            for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
            /usr/bin/xattr -dr com.apple.quarantine \(Shell.quote(newApp.path)) 2>/dev/null || true
            /bin/rm -rf \(Shell.quote(currentApp.path))
            /usr/bin/ditto \(Shell.quote(newApp.path)) \(Shell.quote(currentApp.path))
            /usr/bin/open \(Shell.quote(currentApp.path))
            /bin/rm -rf \(Shell.quote(stagingDir))
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [scriptURL.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            // Detach: the script survives us and performs the swap after we exit.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } else {
            let cmd = "/usr/bin/xattr -dr com.apple.quarantine \(Shell.quote(newApp.path)) 2>/dev/null; "
                + "/bin/rm -rf \(Shell.quote(currentApp.path)) ; "
                + "/usr/bin/ditto \(Shell.quote(newApp.path)) \(Shell.quote(currentApp.path))"
            let ok = Shell.runAsAdmin(cmd, prompt: L("Perch güncellemeyi kurmak için yönetici izni istiyor."))
            guard ok else {
                isRelaunchingForUpdate = false
                throw UpdaterError.adminCancelled
            }
            _ = Shell.run("/usr/bin/open", [currentApp.path])
            try? fm.removeItem(atPath: stagingDir)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - State carried across the update restart

    private func persistStateForRelaunch() {
        let d = UserDefaults.standard
        d.set(LidSleep.shared.isEnabled, forKey: Keys.updateRelaunchLid)
        if KeepAwake.shared.isActive {
            if let endsAt = KeepAwake.shared.endsAt {
                d.set(max(1, endsAt.timeIntervalSinceNow), forKey: Keys.updateRelaunchAwake)
            } else {
                d.set(-1.0, forKey: Keys.updateRelaunchAwake)
            }
        } else {
            d.set(0.0, forKey: Keys.updateRelaunchAwake)
        }
    }

    /// Called once at launch; restores awake/lid state saved before an update restart.
    static func restoreStateAfterRelaunchIfNeeded() {
        let d = UserDefaults.standard
        let awake = d.double(forKey: Keys.updateRelaunchAwake)
        let hadAwakeKey = d.object(forKey: Keys.updateRelaunchAwake) != nil
        let lid = d.bool(forKey: Keys.updateRelaunchLid)
        let hadLidKey = d.object(forKey: Keys.updateRelaunchLid) != nil
        guard hadAwakeKey || hadLidKey else { return }
        d.removeObject(forKey: Keys.updateRelaunchAwake)
        d.removeObject(forKey: Keys.updateRelaunchLid)
        if hadAwakeKey {
            if awake == -1 {
                KeepAwake.shared.start(0)
            } else if awake > 0 {
                KeepAwake.shared.start(awake)
            }
        }
        if hadLidKey, lid {
            LidSleep.shared.takeOverEnabledState()
        }
    }
}

enum UpdaterError: LocalizedError {
    case extractFailed
    case appNotFound
    case identifierMismatch
    case notNewer
    case installFailed
    case adminCancelled

    var errorDescription: String? {
        switch self {
        case .extractFailed: L("İndirilen arşiv açılamadı.")
        case .appNotFound: L("İndirilen pakette Perch.app bulunamadı.")
        case .identifierMismatch: L("İndirilen uygulama Perch ile eşleşmiyor.")
        case .notNewer: L("İndirilen sürüm mevcut sürümden yeni değil.")
        case .installFailed: L("Güncelleme kurulamadı.")
        case .adminCancelled: L("Yönetici izni verilmedi, güncelleme iptal edildi.")
        }
    }
}

extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }

    /// Compares dotted version strings such as "1.2.0". Missing components are treated as 0.
    func versionCompare(_ other: String) -> ComparisonResult {
        let clean: (String) -> [Int] = { s in
            s.split(separator: ".").compactMap { part in
                let digits = part.prefix(while: { $0.isNumber })
                return Int(digits)
            }
        }
        let a = clean(self)
        let b = clean(other)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}
