import AppKit
import SwiftUI

struct CleanerView: View {
    @ObservedObject var model: CleanerModel
    @State private var confirm = false
    @State private var permanently = false

    private let tints: [String: Color] = [
        "caches": Dusk.amber, "logs": Dusk.sky, "xcode": Dusk.violet, "dev": Dusk.teal,
        "installers": Dusk.orange, "mail": Dusk.sky, "trash": Dusk.coral,
    ]
    private let icons: [String: String] = [
        "caches": "shippingbox.fill", "logs": "doc.text.fill", "xcode": "hammer.fill", "dev": "cube.fill",
        "installers": "arrow.down.app.fill", "mail": "envelope.fill", "trash": "trash.fill",
    ]

    private var foundTotal: Int64 { model.categories.reduce(0) { $0 + $1.total } }

    var body: some View {
        if model.started { results } else { start }
    }

    private var start: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: L("Temizlik"), subtitle: L("Silinmesi güvenli önbellek, günlük ve geçici dosyalar")) { EmptyView() }
                    if !FS.hasFullDiskAccess { FullDiskAccessBanner() }
                    StartScanView(
                        symbol: "sparkles", tint: Dusk.amber,
                        title: L("Mac'ini temizleyelim"),
                        subtitle: L("Uygulamaların yeniden oluşturabildiği önbellekleri, eski günlükleri ve artık dosyaları bulurum. Neyin silineceğine sen karar verirsin."),
                        chips: model.categories.map { (icons[$0.id] ?? "folder.fill", L($0.title)) },
                        buttonTitle: L("Taramayı başlat"),
                        action: { model.scan() }
                    ) { EmptyView() }
                }
                .padding(28)
                .frame(minHeight: g.size.height)
            }
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: L("Temizlik"), subtitle: L("Silinmesi güvenli önbellek, günlük ve geçici dosyalar")) {
                    Button { model.scan() } label: { Label(L("Yeniden tara"), systemImage: "arrow.clockwise") }
                        .buttonStyle(DuskButton(kind: .secondary))
                        .disabled(model.scanning || model.deleting)
                }
                if !FS.hasFullDiskAccess { FullDiskAccessBanner() }
                hero
                VStack(spacing: 10) {
                    ForEach(model.categories) { categoryCard($0) }
                }
            }
            .padding(28)
        }
        .confirmationDialog(L("Seçili %d öğe temizlensin mi?", model.selection.count), isPresented: $confirm) {
            Button(permanently ? L("Kalıcı olarak sil") : L("Çöp Kutusu'na taşı"), role: .destructive) {
                model.clean(permanently: permanently)
            }
        } message: {
            Text(L("Toplam %@. Önbellekler uygulamalar tarafından yeniden oluşturulur.", Fmt.bytes(model.selectedSize)))
        }
    }

    private var hero: some View {
        DuskCard(padding: 22, radius: 22) {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    Circle().fill(Dusk.amber.opacity(0.12)).frame(width: 78, height: 78)
                    Circle().strokeBorder(Dusk.amber.opacity(0.3), lineWidth: 1).frame(width: 78, height: 78)
                    if model.scanning { DuskSpinner(size: 34) } else {
                        Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold)).foregroundStyle(Dusk.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.scanning && foundTotal == 0 ? "…" : Fmt.bytes(foundTotal))
                        .font(Dusk.number(38, weight: .bold))
                        .foregroundStyle(Dusk.accent)
                        .contentTransition(.numericText())
                    Text(model.message ?? (model.scanning ? L("Taranıyor…") : L("temizlenebilir alan bulundu")))
                        .font(Dusk.body).foregroundStyle(Dusk.text2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    Button { confirm = true } label: {
                        Label(model.deleting ? L("Temizleniyor…") : L("Temizle · %@", Fmt.bytes(model.selectedSize)),
                              systemImage: "wand.and.stars")
                    }
                    .buttonStyle(DuskButton(kind: .primary, large: true))
                    .disabled(model.selection.isEmpty || model.deleting || model.scanning)
                    HStack(spacing: 7) {
                        DuskCheck(state: permanently) { permanently.toggle() }
                        Text(L("Kalıcı sil")).font(Dusk.caption).foregroundStyle(Dusk.text2)
                            .onTapGesture { permanently.toggle() }
                    }
                }
            }
        }
        .background(
            RadialGradient(colors: [Dusk.amber.opacity(0.12), .clear], center: .leading, startRadius: 0, endRadius: 320)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
    }

    private func categoryCard(_ c: CleanCategory) -> some View {
        let tint = tints[c.id] ?? Dusk.amber
        let open = model.expanded.contains(c.id)
        return DuskCard(padding: 0, radius: 16) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    DuskCheck(state: c.items.isEmpty ? false : model.categoryState(c)) { model.toggleCategory(c) }
                        .disabled(c.items.isEmpty)
                    IconBadge(symbol: icons[c.id] ?? "folder.fill", tint: tint, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(c.title)).font(Dusk.heading(14))
                        Text(L(c.detail)).font(Dusk.caption).foregroundStyle(Dusk.text3).lineLimit(1)
                    }
                    Spacer()
                    if !c.scanned {
                        DuskSpinner(size: 16)
                    } else {
                        Text(c.total > 0 ? Fmt.bytes(c.total) : L("Boş"))
                            .font(Dusk.number(15))
                            .foregroundStyle(c.total > 0 ? Dusk.text : Dusk.text3)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Dusk.text3)
                        .rotationEffect(.degrees(open ? 0 : -90))
                        .opacity(c.items.isEmpty ? 0.3 : 1)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !c.items.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        if open { model.expanded.remove(c.id) } else { model.expanded.insert(c.id) }
                    }
                }

                if open {
                    Rectangle().fill(Dusk.stroke).frame(height: 1)
                    LazyVStack(spacing: 2) {
                        ForEach(c.items) { item in itemRow(item, tint: tint) }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func itemRow(_ item: CleanItem, tint: Color) -> some View {
        HStack(spacing: 10) {
            DuskCheck(state: model.selection.contains(item.id)) {
                model.selection.set(item.id, !model.selection.contains(item.id))
            }
            Text(item.url.lastPathComponent).font(Dusk.body).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Fmt.bytes(item.size)).font(Dusk.number(12.5, weight: .medium)).foregroundStyle(Dusk.text2)
            IconButton(symbol: "arrow.up.forward.app", help: L("Finder'da göster")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            .scaleEffect(0.85)
        }
        .rowChrome()
        .padding(.leading, 34)
    }
}
