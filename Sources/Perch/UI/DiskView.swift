import AppKit
import SwiftUI

struct DiskView: View {
    @ObservedObject var model: DiskModel
    @State private var confirm = false

    var body: some View {
        if model.root == nil && !model.scanning { start } else { results }
    }

    private var start: some View {
        GeometryReader { g in
            FadingScroll {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: L("Büyük Dosyalar"), subtitle: L("Diskinde en çok yer kaplayan klasör ve dosyalar")) { EmptyView() }
                    if !model.hasFDA { FullDiskAccessBanner() }
                    StartScanView(
                        symbol: "square.stack.3d.up.fill", tint: Dusk.violet,
                        title: L("Yer kaplayanları bul"),
                        subtitle: L("Seçtiğin klasörü baştan sona tarar, klasörleri boyuta göre sıralar ve 100 MB üzerindeki dosyaları listelerim."),
                        chips: [("house.fill", model.rootPath == FS.home ? L("Ana klasör") : model.rootPath.replacingOccurrences(of: FS.home, with: "~")),
                                ("folder.fill", L("Klasör boyutları")), ("doc.fill", L("≥ 100 MB dosyalar"))],
                        buttonTitle: L("Taramayı başlat"),
                        action: { model.scan() }
                    ) {
                        Button { model.chooseRoot() } label: { Label(L("Başka bir klasör seç…"), systemImage: "folder") }
                            .buttonStyle(DuskButton(kind: .ghost))
                    }
                }
                .padding(28)
                .frame(minHeight: g.size.height)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: L("Büyük Dosyalar"),
                       subtitle: model.rootPath.replacingOccurrences(of: FS.home, with: "~")) {
                DuskSegmented(selection: $model.mode, options: DiskModel.Mode.allCases.map { ($0, $0.title) })
                IconButton(symbol: "folder", help: L("Başka bir klasör tara")) { model.chooseRoot() }
                IconButton(symbol: "arrow.clockwise", help: L("Yeniden tara")) { model.scan() }
                    .disabled(model.scanning)
            }
            if !model.hasFDA { FullDiskAccessBanner() }

            if model.scanning && model.root == nil {
                scanning
            } else if model.mode == .folders {
                breadcrumb
                list(folderRows)
            } else {
                list(fileRows)
            }
        }
        .padding(.horizontal, 28).padding(.top, 28)
        .overlay(alignment: .bottom) {
            if !model.selection.isEmpty { actionBar.padding(20).transition(.move(edge: .bottom).combined(with: .opacity)) }
            else if let m = model.message { Tag(text: m, tint: Dusk.text2).padding(18) }
        }
        .animation(.easeOut(duration: 0.18), value: model.selection.isEmpty)
        .confirmationDialog(L("%d öğe Çöp Kutusu'na taşınsın mı?", model.selection.count), isPresented: $confirm) {
            Button(L("Çöp Kutusu'na taşı"), role: .destructive) { model.trashSelected() }
        }
    }

    // MARK: Pieces

    private var scanning: some View {
        VStack(spacing: 16) {
            DuskSpinner(size: 44)
            Text(L("Taranıyor… %@ dosya · %@", model.scannedFiles.formatted(), Fmt.bytes(model.scannedBytes)))
                .font(Dusk.number(14, weight: .medium)).foregroundStyle(Dusk.text2)
            Button(L("Durdur")) { model.cancel() }.buttonStyle(DuskButton(kind: .secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.breadcrumb) { n in
                    let isCurrent = n === model.current
                    Button {
                        model.current = n
                        model.selection.removeAll()
                    } label: {
                        HStack(spacing: 5) {
                            if n.parent == nil { Image(systemName: "house.fill").font(.system(size: 10)) }
                            Text(n.parent == nil ? n.path.replacingOccurrences(of: FS.home, with: "~") : n.name)
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isCurrent ? Dusk.ink : Dusk.text2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(isCurrent ? AnyShapeStyle(Dusk.accent) : AnyShapeStyle(Dusk.surfaceHi)))
                    }
                    .buttonStyle(.plain)
                    if !isCurrent { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Dusk.text3) }
                }
                if model.scanning { DuskSpinner(size: 14).padding(.leading, 4) }
            }
        }
    }

    private struct RowData: Identifiable {
        let id: String
        let name: String
        let sub: String?
        let size: Int64
        let isDir: Bool
        let node: DirNode?
    }

    private var folderRows: [RowData] {
        guard let cur = model.current else { return [] }
        return cur.children.map { RowData(id: $0.path, name: $0.name, sub: nil, size: $0.size, isDir: true, node: $0) }
            + cur.files.map { RowData(id: $0.path, name: $0.name, sub: nil, size: $0.size, isDir: false, node: nil) }
    }

    private var fileRows: [RowData] {
        model.bigFiles.map {
            RowData(id: $0.path, name: $0.name,
                    sub: ($0.path as NSString).deletingLastPathComponent.replacingOccurrences(of: FS.home, with: "~"),
                    size: $0.size, isDir: false, node: nil)
        }
    }

    private func list(_ rows: [RowData]) -> some View {
        let maxSize = max(rows.map(\.size).max() ?? 1, 1)
        return DuskCard(padding: 6, radius: 18) {
            if rows.isEmpty {
                EmptyState(symbol: "doc.text.magnifyingglass", text: L("100 MB üzerinde dosya yok"))
                    .frame(minHeight: 220)
            } else {
                FadingScroll(fade: 14) {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { r in row(r, max: maxSize) }
                    }
                    .padding(.bottom, model.selection.isEmpty ? 4 : 70)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 20)
    }

    private func row(_ r: RowData, max: Int64) -> some View {
        let selected = model.selection.contains(r.id)
        return HStack(spacing: 12) {
            DuskCheck(state: selected) { model.selection.set(r.id, !selected) }
            Image(systemName: r.isDir ? "folder.fill" : "doc.fill")
                .font(.system(size: 15))
                .foregroundStyle(r.isDir ? Dusk.violet : Dusk.text3)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let s = r.sub {
                    Text(s).font(Dusk.caption).foregroundStyle(Dusk.text3).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            DuskBar(value: Double(r.size) / Double(max),
                    fill: AnyShapeStyle(Dusk.gradient(Dusk.violet, Dusk.sky)), height: 5)
                .frame(width: 110)
            Text(Fmt.bytes(r.size)).font(Dusk.number(13)).frame(width: 82, alignment: .trailing)
            if r.isDir {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Dusk.text3)
            } else {
                Color.clear.frame(width: 7)
            }
        }
        .rowChrome(selected: selected)
        .onTapGesture {
            if let n = r.node { model.open(n) } else { model.selection.set(r.id, !selected) }
        }
        .contextMenu {
            Button(L("Finder'da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.id)]) }
            Button(L("Yolu kopyala")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(r.id, forType: .string)
            }
        }
    }

    private var actionBar: some View {
        let total = model.selection.reduce(Int64(0)) { sum, path in
            sum + (folderRows.first { $0.id == path }?.size ?? fileRows.first { $0.id == path }?.size ?? 0)
        }
        return ActionBar {
            Text(L("%d öğe seçildi", model.selection.count)).font(Dusk.heading(13))
            Tag(text: Fmt.bytes(total), tint: Dusk.amber)
        } actions: {
            Button(L("Seçimi temizle")) { model.selection.removeAll() }.buttonStyle(DuskButton(kind: .ghost))
            if model.selection.count == 1, let p = model.selection.first {
                Button(L("Finder'da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    .buttonStyle(DuskButton(kind: .secondary))
            }
            Button { confirm = true } label: { Label(L("Çöp Kutusu'na taşı"), systemImage: "trash") }
                .buttonStyle(DuskButton(kind: .danger))
        }
    }
}
