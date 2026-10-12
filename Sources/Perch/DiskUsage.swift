import AppKit
import SwiftUI

final class DirNode: Identifiable {
    let name: String
    weak var parent: DirNode?
    var size: Int64 = 0
    var children: [DirNode] = []
    var files: [FileEntry] = []
    /// Depth cap reached during scan: subfolders weren't materialised yet.
    var truncated = false
    private let rootPath: String?

    init(name: String, parent: DirNode?, rootPath: String? = nil) {
        self.name = name
        self.parent = parent
        self.rootPath = rootPath
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var path: String {
        if let rootPath { return rootPath }
        return (parent?.path ?? "") + "/" + name
    }
}

struct FileEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
    var name: String { (path as NSString).lastPathComponent }
}

enum DiskScanner {
    static let maxDepth = 4
    static let dirFileThreshold: Int64 = 20 << 20
    static let bigFileThreshold: Int64 = 100 << 20

    final class Progress: @unchecked Sendable {
        var files = 0
        var bytes: Int64 = 0
        var cancelled = false
    }

    /// One fts pass: builds a size tree down to `maxDepth` and collects big files anywhere below.
    static func scan(root: String, progress: Progress) -> (DirNode, [FileEntry]) {
        let rootNode = DirNode(name: (root as NSString).lastPathComponent, parent: nil, rootPath: root)
        var big: [FileEntry] = []
        // Parallel stacks: materialised node (nil below depth cap) and running size.
        var nodes: [DirNode?] = []
        var sizes: [Int64] = []
        let skip: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/cores"]
        let skipProtected = !FS.hasFullDiskAccess

        FS.walk(root) { ent, fts in
            let e = ent.pointee
            let level = Int(e.fts_level)
            switch Int32(e.fts_info) {
            case FTS_D:
                let path = String(cString: e.fts_path)
                if level > 0, skip.contains(path) || (skipProtected && FS.isProtected(path)) {
                    fts_set(fts, ent, FTS_SKIP)
                    return true
                }
                var node: DirNode?
                if level == 0 {
                    node = rootNode
                } else if level <= maxDepth, let parent = nodes.last ?? nil {
                    let n = DirNode(name: (path as NSString).lastPathComponent, parent: parent)
                    if level == maxDepth { n.truncated = true }
                    parent.children.append(n)
                    node = n
                }
                nodes.append(node)
                sizes.append(0)
            case FTS_DP:
                guard let size = sizes.popLast(), let node = nodes.popLast() else { return true }
                node?.size = size
                if !sizes.isEmpty { sizes[sizes.count - 1] += size }
            case FTS_F, FTS_SL, FTS_DEFAULT:
                let size = Int64(e.fts_statp.pointee.st_blocks) * 512
                if !sizes.isEmpty { sizes[sizes.count - 1] += size }
                progress.files += 1
                progress.bytes += size
                if size >= dirFileThreshold {
                    let entry = FileEntry(path: String(cString: e.fts_path), size: size)
                    if let holder = nodes.last(where: { $0 != nil }) ?? nil { holder.files.append(entry) }
                    if size >= bigFileThreshold { big.append(entry) }
                }
                if progress.files & 4095 == 0 && progress.cancelled { return false }
            default:
                break
            }
            return true
        }
        sortTree(rootNode)
        return (rootNode, big.sorted { $0.size > $1.size })
    }

    private static func sortTree(_ n: DirNode) {
        n.children.sort { $0.size > $1.size }
        n.files.sort { $0.size > $1.size }
        n.children.forEach(sortTree)
    }
}

@MainActor
final class DiskModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case folders = "Klasörler", files = "Büyük dosyalar"
        var title: String { L(rawValue) }
    }

    @Published var mode: Mode = .folders
    @Published var rootPath = FS.home
    @Published private(set) var root: DirNode?
    @Published var current: DirNode?
    @Published private(set) var bigFiles: [FileEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var scannedBytes: Int64 = 0
    @Published var selection: Set<String> = []
    @Published var message: String?
    @Published private(set) var hasFDA = FS.hasFullDiskAccess
    private var progress: DiskScanner.Progress?
    private var ticker: Timer?

    func scanIfNeeded() { if root == nil && !scanning { scan() } }

    func chooseRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: rootPath)
        guard p.runModal() == .OK, let url = p.url else { return }
        rootPath = url.path
        scan()
    }

    func scan() {
        progress?.cancelled = true
        let prog = DiskScanner.Progress()
        progress = prog
        scanning = true
        selection.removeAll()
        message = nil
        hasFDA = FS.hasFullDiskAccess
        startTicker(prog)
        let path = rootPath
        Task.detached(priority: .utility) {
            let (tree, big) = DiskScanner.scan(root: path, progress: prog)
            await MainActor.run {
                guard self.progress === prog, !prog.cancelled else { return }
                self.root = tree
                self.current = tree
                self.bigFiles = big
                self.finish()
            }
        }
    }

    /// Expands a folder beyond the initial depth cap by scanning just that subtree.
    func open(_ node: DirNode) {
        selection.removeAll()
        guard node.truncated else {
            current = node
            return
        }
        let prog = DiskScanner.Progress()
        progress = prog
        scanning = true
        startTicker(prog)
        let path = node.path
        Task.detached(priority: .utility) {
            let (sub, _) = DiskScanner.scan(root: path, progress: prog)
            await MainActor.run {
                guard self.progress === prog else { return }
                node.children = sub.children
                node.children.forEach { $0.parent = node }
                node.files = sub.files
                node.truncated = false
                self.current = node
                self.finish()
            }
        }
    }

    func cancel() {
        progress?.cancelled = true
        finish()
    }

    private func startTicker(_ prog: DiskScanner.Progress) {
        ticker?.invalidate()
        scannedFiles = 0
        scannedBytes = 0
        let t = Timer(timeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                self.scannedFiles = prog.files
                self.scannedBytes = prog.bytes
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func finish() {
        ticker?.invalidate()
        ticker = nil
        scanning = false
    }

    var breadcrumb: [DirNode] {
        var out: [DirNode] = []
        var n = current
        while let x = n { out.insert(x, at: 0); n = x.parent }
        return out
    }

    func trashSelected() {
        let paths = Array(selection)
        guard !paths.isEmpty else { return }
        Task {
            let res = await FS.recycle(paths.map(URL.init(fileURLWithPath:)), adminFallback: false)
            let failedPaths = Set(res.failed.map(\.path))
            let removed = Set(paths).subtracting(failedPaths)
            prune(removed)
            selection.removeAll()
            message = res.failed.isEmpty ? L("%d öğe Çöp Kutusu'na taşındı.", res.ok) : L("%d öğe taşınamadı (izin yok).", res.failed.count)
        }
    }

    /// Removes deleted paths from the in-memory tree and fixes ancestor sizes.
    private func prune(_ removed: Set<String>) {
        guard !removed.isEmpty else { return }
        func subtract(_ size: Int64, from node: DirNode?) {
            var n = node
            while let x = n { x.size -= size; n = x.parent }
        }
        bigFiles.removeAll { removed.contains($0.path) }
        func visit(_ node: DirNode) {
            for f in node.files where removed.contains(f.path) { subtract(f.size, from: node) }
            node.files.removeAll { removed.contains($0.path) }
            for c in node.children where removed.contains(c.path) { subtract(c.size, from: node) }
            node.children.removeAll { removed.contains($0.path) }
            node.children.forEach(visit)
        }
        if let root { visit(root) }
        objectWillChange.send()
    }
}

struct DiskView: View {
    @ObservedObject var model: DiskModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.hasFDA { FullDiskAccessBanner() }
            Divider()
            if model.scanning && model.root == nil {
                scanningPlaceholder
            } else if model.mode == .folders {
                folderList
            } else {
                fileList
            }
            Divider()
            footer
        }
        .onAppear { model.scanIfNeeded() }
        .confirmationDialog(L("%d öğe Çöp Kutusu'na taşınsın mı?", model.selection.count), isPresented: $confirm) {
            Button(L("Çöp Kutusu'na taşı"), role: .destructive) { model.trashSelected() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Büyük dosyalar")).font(.title2.bold())
                Text(model.rootPath.replacingOccurrences(of: FS.home, with: "~")).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("", selection: $model.mode) {
                ForEach(DiskModel.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            Button { model.chooseRoot() } label: { Image(systemName: "folder") }.help(L("Başka bir klasör tara"))
            Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.help(L("Yeniden tara"))
                .disabled(model.scanning)
        }
        .padding()
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(L("Taranıyor… %@ dosya · %@", model.scannedFiles.formatted(), Fmt.bytes(model.scannedBytes)))
                .monospacedDigit().foregroundStyle(.secondary)
            Button(L("Durdur")) { model.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderList: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.breadcrumb) { n in
                        Button(n.parent == nil ? n.path.replacingOccurrences(of: FS.home, with: "~") : n.name) {
                            model.current = n
                            model.selection.removeAll()
                        }
                        .buttonStyle(.link)
                        if n !== model.current { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    if model.scanning { ProgressView().controlSize(.mini).padding(.leading, 6) }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            if let cur = model.current {
                List(selection: $model.selection) {
                    ForEach(cur.children) { c in
                        sizeRow(name: c.name, path: c.path, size: c.size, of: cur.size, isDir: true)
                            .tag(c.path)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(c) }
                    }
                    ForEach(cur.files) { f in
                        sizeRow(name: f.name, path: f.path, size: f.size, of: cur.size, isDir: false).tag(f.path)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var fileList: some View {
        List(selection: $model.selection) {
            ForEach(model.bigFiles) { f in
                sizeRow(name: f.name, path: f.path, size: f.size, of: model.bigFiles.first?.size ?? 1, isDir: false, showPath: true)
                    .tag(f.path)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.bigFiles.isEmpty && !model.scanning {
                Text(L("100 MB üzerinde dosya yok")).foregroundStyle(.secondary)
            }
        }
    }

    private func sizeRow(name: String, path: String, size: Int64, of total: Int64, isDir: Bool, showPath: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isDir ? "folder.fill" : "doc.fill")
                .foregroundStyle(isDir ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if showPath {
                    Text((path as NSString).deletingLastPathComponent.replacingOccurrences(of: FS.home, with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            GeometryReader { g in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(2, g.size.width * CGFloat(Double(size) / Double(max(total, 1)))))
                    }
            }
            .frame(width: 90, height: 6)
            Text(Fmt.bytes(size)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(L("Finder'da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button(L("Yolu kopyala")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let m = model.message {
                Text(m).foregroundStyle(.secondary)
            } else {
                Text(model.mode == .folders ? L("Çift tıkla: klasöre gir · sağ tık: Finder'da göster") : L("≥ 100 MB dosyalar, büyükten küçüğe"))
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            if model.selection.count == 1, let p = model.selection.first {
                Button(L("Finder'da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
            Button(role: .destructive) { confirm = true } label: {
                Label(L("Çöp Kutusu'na taşı"), systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
        }
        .padding()
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text(L("Fotoğraflar, Mail ve uygulama kapsayıcıları gibi korumalı klasörler atlanıyor. Hepsini görmek için Perch'e Tam Disk Erişimi ver, sonra yeniden tara."))
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(L("Ayarları aç")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}
