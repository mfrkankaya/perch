import AppKit
import SwiftUI

struct InstalledApp: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    var size: Int64?
}

struct RelatedFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let group: String
    var size: Int64
    let isBundle: Bool
}

enum AppScanner {
    static func installedApps() -> [InstalledApp] {
        var roots = ["/Applications", FS.home + "/Applications", "/Applications/Utilities"]
        var seen = Set<String>()
        var out: [InstalledApp] = []
        let fm = FileManager.default
        while let root = roots.first {
            roots.removeFirst()
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names {
                let path = root + "/" + n
                if n.hasSuffix(".app") {
                    guard seen.insert(path).inserted else { continue }
                    let b = Bundle(url: URL(fileURLWithPath: path))
                    let info = b?.infoDictionary ?? [:]
                    let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                        ?? (n as NSString).deletingPathExtension
                    out.append(InstalledApp(url: URL(fileURLWithPath: path), name: name, bundleID: b?.bundleIdentifier,
                                            version: info["CFBundleShortVersionString"] as? String))
                } else if root == "/Applications" || root == FS.home + "/Applications", FS.isDirectory(path),
                          n != "Utilities", !n.hasPrefix(".") {
                    roots.append(path) // one level of vendor folders, e.g. /Applications/Adobe…
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let libraryDirs: [(String, String)] = [
        ("Library/Application Support", "Uygulama Desteği"),
        ("Library/Caches", "Önbellek"),
        ("Library/Preferences", "Tercihler"),
        ("Library/Preferences/ByHost", "Tercihler"),
        ("Library/Containers", "Kapsayıcılar"),
        ("Library/Group Containers", "Grup Kapsayıcıları"),
        ("Library/Saved Application State", "Kayıtlı Durum"),
        ("Library/Logs", "Günlükler"),
        ("Library/HTTPStorages", "Web Verisi"),
        ("Library/WebKit", "Web Verisi"),
        ("Library/Cookies", "Çerezler"),
        ("Library/LaunchAgents", "Başlangıç Öğeleri"),
        ("Library/Application Scripts", "Betikler"),
        ("Library/Internet Plug-Ins", "Eklentiler"),
        ("Library/Services", "Servisler"),
    ]
    private static let systemDirs: [(String, String)] = [
        ("/Library/Application Support", "Sistem · Uygulama Desteği"),
        ("/Library/Caches", "Sistem · Önbellek"),
        ("/Library/Preferences", "Sistem · Tercihler"),
        ("/Library/LaunchAgents", "Sistem · Başlangıç Öğeleri"),
        ("/Library/LaunchDaemons", "Sistem · Arka Plan Servisleri"),
        ("/Library/PrivilegedHelperTools", "Sistem · Yardımcı Araçlar"),
        ("/Library/Logs", "Sistem · Günlükler"),
        ("/private/var/db/receipts", "Sistem · Kurulum Kayıtları"),
    ]

    /// Pearcleaner-style matching on bundle id and app name, deliberately conservative
    /// so generic names (e.g. "app") never match.
    static func relatedFiles(for app: InstalledApp) -> [RelatedFile] {
        var tokens: [String] = []
        let bid = app.bundleID?.lowercased()
        if let bid { tokens.append(bid) }
        let name = app.name.lowercased()
        let fileName = app.url.deletingPathExtension().lastPathComponent.lowercased()
        let generic: Set<String> = ["app", "apps", "helper", "update", "updater", "data", "cache", "caches", "google", "microsoft", "apple"]
        for n in [name, fileName, name.replacingOccurrences(of: " ", with: ""), fileName.replacingOccurrences(of: " ", with: "")]
        where n.count >= 3 && !generic.contains(n) && !tokens.contains(n) {
            tokens.append(n)
        }

        func matches(_ entry: String) -> Bool {
            let e = entry.lowercased()
            let stem = (e as NSString).deletingPathExtension
            if let bid {
                if e == bid || e.hasPrefix(bid + ".") || stem == bid || e.hasSuffix("." + bid) { return true }
                if e.contains(bid) { return true } // group containers: TEAMID.com.vendor.app, receipts, helpers
            }
            for t in tokens where t != bid {
                if e == t || stem == t || e.hasPrefix(t + ".") { return true }
            }
            return false
        }

        var out: [RelatedFile] = [RelatedFile(url: app.url, group: "Uygulama", size: 0, isBundle: true)]
        var seen: Set<String> = [app.url.path]
        let fm = FileManager.default
        let dirs = libraryDirs.map { (FS.home + "/" + $0.0, $0.1) } + systemDirs
        for (dir, label) in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where matches(n) {
                let p = dir + "/" + n
                if seen.insert(p).inserted {
                    out.append(RelatedFile(url: URL(fileURLWithPath: p), group: label, size: 0, isBundle: false))
                }
            }
        }
        return out
    }
}

@MainActor
final class AppsModel: ObservableObject {
    enum Sort: String, CaseIterable { case name = "Ad", size = "Boyut" }

    @Published var apps: [InstalledApp] = []
    @Published var search = ""
    @Published var sort: Sort = .name
    @Published var selectedID: String? {
        didSet { if let selectedID, selectedID != oldValue { loadRelated(selectedID) } }
    }
    @Published var related: [RelatedFile] = []
    @Published var relatedSelection: Set<String> = []
    @Published var loading = false
    @Published var loadingRelated = false
    @Published var working = false
    @Published var message: String?
    private var sizeTask: Task<Void, Never>?

    var visibleApps: [InstalledApp] {
        let list = search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search)
        }
        return sort == .name ? list : list.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedID } }
    var selectedSize: Int64 { related.filter { relatedSelection.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func loadIfNeeded() { if apps.isEmpty && !loading { load() } }

    func load() {
        loading = true
        sizeTask?.cancel()
        Task {
            let list = await Task.detached(priority: .userInitiated) { AppScanner.installedApps() }.value
            apps = list
            loading = false
            computeSizes()
        }
    }

    private func computeSizes() {
        let targets = apps.map(\.url.path)
        sizeTask = Task(priority: .background) { [weak self] in
            for path in targets {
                if Task.isCancelled { return }
                let size = await Task.detached(priority: .background) { FS.allocatedSize(path) }.value
                guard let self, let i = self.apps.firstIndex(where: { $0.id == path }) else { return }
                self.apps[i].size = size
            }
        }
    }

    private func loadRelated(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        loadingRelated = true
        related = []
        relatedSelection = []
        message = nil
        Task {
            let files = await Task.detached(priority: .userInitiated) { () -> [RelatedFile] in
                AppScanner.relatedFiles(for: app).map { f in
                    var f = f
                    f.size = FS.allocatedSize(f.url.path)
                    return f
                }
            }.value
            guard selectedID == id else { return }
            related = files
            relatedSelection = Set(files.map(\.id))
            loadingRelated = false
        }
    }

    var isRunning: Bool {
        guard let bid = selectedApp?.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }

    func removeSelected() {
        guard let app = selectedApp else { return }
        let urls = related.filter { relatedSelection.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        working = true
        Task {
            if let bid = app.bundleID {
                for r in NSRunningApplication.runningApplications(withBundleIdentifier: bid) { r.terminate() }
                try? await Task.sleep(for: .seconds(1.5))
            }
            let res = await Task.detached { await FS.recycle(urls, adminFallback: true) }.value
            working = false
            MainWindowController.shared.bringToFront()
            let bundleGone = !FileManager.default.fileExists(atPath: app.url.path)
            if res.failed.isEmpty {
                message = L("%@: %d öğe Çöp Kutusu'na taşındı.", app.name, res.ok)
            } else {
                message = L("%d öğe taşınamadı.", res.failed.count)
            }
            if bundleGone {
                apps.removeAll { $0.id == app.id }
                selectedID = nil
                related = []
            } else {
                loadRelated(app.id)
            }
        }
    }
}
