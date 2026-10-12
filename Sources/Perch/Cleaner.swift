import AppKit
import SwiftUI

struct CleanItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let size: Int64
}

struct CleanCategory: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let selectedByDefault: Bool
    /// Returns candidate paths; everything returned is regenerable or disposable.
    let discover: () -> [URL]
    var items: [CleanItem] = []
    var scanned = false
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

private func children(_ path: String, excluding: Set<String> = []) -> [URL] {
    let full = path.hasPrefix("/") ? path : FS.home + "/" + path
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: full) else { return [] }
    return names.filter { $0 != ".DS_Store" && !excluding.contains($0) }
        .map { URL(fileURLWithPath: full).appendingPathComponent($0) }
}

private func existing(_ paths: [String]) -> [URL] {
    paths.map { FS.home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }.map(URL.init(fileURLWithPath:))
}

@MainActor
final class CleanerModel: ObservableObject {
    @Published var categories: [CleanCategory]
    @Published var selection: Set<String> = []
    @Published var scanning = false
    @Published var deleting = false
    @Published var message: String?
    @Published var expanded: Set<String> = []

    init() {
        categories = [
            CleanCategory(id: "caches", title: "Uygulama önbellekleri", detail: "~/Library/Caches – uygulamalar gerektiğinde yeniden oluşturur",
                          icon: "shippingbox", selectedByDefault: true,
                          discover: { children("Library/Caches", excluding: ["com.apple.HomeKit", "CloudKit", "com.apple.bird", "FamilyCircle"]) }),
            CleanCategory(id: "logs", title: "Günlükler ve çökme raporları", detail: "~/Library/Logs",
                          icon: "doc.text", selectedByDefault: true,
                          discover: { children("Library/Logs") }),
            CleanCategory(id: "xcode", title: "Xcode artıkları", detail: "DerivedData, Previews, eski cihaz destek dosyaları",
                          icon: "hammer", selectedByDefault: true,
                          discover: {
                              children("Library/Developer/Xcode/DerivedData")
                                  + children("Library/Developer/Xcode/iOS DeviceSupport")
                                  + children("Library/Developer/Xcode/watchOS DeviceSupport")
                                  + children("Library/Developer/Xcode/UserData/Previews")
                                  + existing(["Library/Developer/CoreSimulator/Caches"])
                          }),
            CleanCategory(id: "dev", title: "Geliştirici paket önbellekleri", detail: "npm, pnpm, yarn, bun, gradle, pip, cargo, CocoaPods…",
                          icon: "cube.box", selectedByDefault: true,
                          discover: {
                              existing([".npm/_cacache", ".npm/_npx", ".pnpm-store", "Library/pnpm/store", ".yarn/berry/cache",
                                        ".bun/install/cache", ".gradle/caches", ".gradle/wrapper/dists", ".cargo/registry/cache",
                                        ".cocoapods/repos", ".expo/native-modules-cache", ".m2/repository", ".cache/pip",
                                        ".cache/huggingface/xet", ".cache/puppeteer", ".cache/ms-playwright", ".cache/node-gyp",
                                        ".cache/yarn", ".cache/typescript", ".cache/prisma", ".cache/turbo"])
                          }),
            CleanCategory(id: "installers", title: "İndirilen yükleyiciler", detail: "~/Downloads içindeki .dmg, .pkg, .xip dosyaları",
                          icon: "arrow.down.app", selectedByDefault: false,
                          discover: {
                              children("Downloads").filter { ["dmg", "pkg", "xip", "mpkg"].contains($0.pathExtension.lowercased()) }
                          }),
            CleanCategory(id: "mail", title: "Mail ek indirmeleri", detail: "Mail'in açtığın eklerin kopyaları",
                          icon: "envelope", selectedByDefault: false,
                          discover: {
                              // Inside another app's container: only readable without a prompt when Full Disk Access is on.
                              FS.hasFullDiskAccess ? children("Library/Containers/com.apple.mail/Data/Library/Mail Downloads") : []
                          }),
            CleanCategory(id: "trash", title: "Çöp Kutusu", detail: "Kalıcı olarak silinir",
                          icon: "trash", selectedByDefault: false,
                          discover: { children(".Trash") }),
        ]
    }

    var selectedSize: Int64 {
        categories.flatMap(\.items).filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func scanIfNeeded() { if !categories.contains(where: \.scanned) { scan() } }

    func scan() {
        guard !scanning else { return }
        scanning = true
        message = nil
        selection.removeAll()
        for i in categories.indices { categories[i].scanned = false; categories[i].items = [] }
        let jobs = categories.map { ($0.id, $0.discover) }
        Task {
            await withTaskGroup(of: (String, [CleanItem]).self) { group in
                for (id, discover) in jobs {
                    group.addTask(priority: .utility) {
                        let items = discover()
                            .map { CleanItem(url: $0, size: FS.allocatedSize($0.path)) }
                            .filter { $0.size > 0 }
                            .sorted { $0.size > $1.size }
                        return (id, items)
                    }
                }
                for await (id, items) in group {
                    guard let i = categories.firstIndex(where: { $0.id == id }) else { continue }
                    categories[i].items = items
                    categories[i].scanned = true
                    if categories[i].selectedByDefault { selection.formUnion(items.map(\.id)) }
                }
            }
            scanning = false
        }
    }

    func toggleCategory(_ c: CleanCategory) {
        let ids = Set(c.items.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func categoryState(_ c: CleanCategory) -> Bool? {
        let ids = Set(c.items.map(\.id))
        if ids.isEmpty { return false }
        let n = ids.intersection(selection).count
        return n == 0 ? false : (n == ids.count ? true : nil)
    }

    func clean(permanently: Bool) {
        let chosen = categories.flatMap { c in c.items.map { (c.id, $0) } }.filter { selection.contains($0.1.id) }
        guard !chosen.isEmpty else { return }
        deleting = true
        let freed = selectedSize
        Task.detached(priority: .userInitiated) {
            var failed = 0
            for (cat, item) in chosen {
                do {
                    // Trash contents must be removed for real; moving them to the Trash again is meaningless.
                    if permanently || cat == "trash" {
                        try FileManager.default.removeItem(at: item.url)
                    } else {
                        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                    }
                } catch {
                    if FileManager.default.fileExists(atPath: item.url.path) { failed += 1 }
                }
            }
            let f = failed
            await MainActor.run {
                self.deleting = false
                self.message = f == 0
                    ? (permanently ? L("%@ temizlendi.", Fmt.bytes(freed)) : L("%@ temizlendi (Çöp Kutusu'na taşındı).", Fmt.bytes(freed)))
                    : L("Temizlendi; %d öğe kullanımda ya da korumalı olduğu için atlandı.", f)
                self.scan()
            }
        }
    }
}
