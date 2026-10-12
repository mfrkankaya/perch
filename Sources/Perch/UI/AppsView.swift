import AppKit
import SwiftUI

struct AppsView: View {
    @ObservedObject var model: AppsModel
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: L("Uygulama Kaldır"), subtitle: L("Uygulamayı ve geride bıraktığı her şeyi sil")) {
                EmptyView()
            }
            HStack(alignment: .top, spacing: 14) {
                appList.frame(width: 300)
                detail
            }
        }
        .padding(28)
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: List

    private var appList: some View {
        DuskCard(padding: 10, radius: 18) {
            VStack(spacing: 10) {
                DuskSearchField(text: $model.search, placeholder: L("Ara"))
                DuskSegmented(selection: $model.sort,
                              options: AppsModel.Sort.allCases.map { ($0, L($0.rawValue)) }, compact: true)
                if model.loading {
                    DuskSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.visibleApps) { app in appRow(app) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let selected = model.selectedID == app.id
        return HStack(spacing: 10) {
            AppIconView(path: app.url.path, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let v = app.version { Text(v).font(Dusk.caption).foregroundStyle(Dusk.text3).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Text(app.size.map(Fmt.bytes) ?? "…").font(Dusk.number(11.5, weight: .medium)).foregroundStyle(Dusk.text2)
        }
        .rowChrome(selected: selected)
        .onTapGesture { model.selectedID = app.id }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            DuskCard(padding: 0, radius: 18) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        AppIconView(path: app.url.path, size: 64)
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.name).font(Dusk.title(22))
                            Text(app.bundleID ?? app.url.path).font(Dusk.caption).foregroundStyle(Dusk.text3)
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                if let v = app.version { Tag(text: "v\(v)") }
                                if let s = app.size { Tag(text: Fmt.bytes(s), tint: Dusk.violet) }
                                if model.isRunning { Tag(text: L("Uygulama açık – kaldırırken kapatılacak"), tint: Dusk.amber) }
                            }
                        }
                        Spacer()
                    }
                    .padding(20)
                    Rectangle().fill(Dusk.stroke).frame(height: 1)

                    if model.loadingRelated {
                        VStack(spacing: 12) {
                            DuskSpinner()
                            Text(L("Dosyalar aranıyor…")).font(Dusk.body).foregroundStyle(Dusk.text2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        relatedList
                    }

                    Rectangle().fill(Dusk.stroke).frame(height: 1)
                    HStack {
                        Text(model.message ?? L("%d öğe seçildi", model.relatedSelection.count))
                            .font(Dusk.caption).foregroundStyle(Dusk.text2)
                        Spacer()
                        Button { confirm = true } label: {
                            Label(model.working ? L("Kaldırılıyor…") : L("Kaldır · %@", Fmt.bytes(model.selectedSize)),
                                  systemImage: "xmark.bin.fill")
                        }
                        .buttonStyle(DuskButton(kind: .primary, large: true))
                        .disabled(model.relatedSelection.isEmpty || model.working || model.loadingRelated)
                    }
                    .padding(16)
                }
            }
            .frame(maxHeight: .infinity)
            .confirmationDialog(L("%@ için %d öğe Çöp Kutusu'na taşınsın mı?", app.name, model.relatedSelection.count),
                                isPresented: $confirm) {
                Button(L("Kaldır"), role: .destructive) { model.removeSelected() }
            } message: {
                Text(L("Çöp Kutusu'nu boşaltana kadar geri alabilirsin."))
            }
        } else {
            DuskCard(radius: 18) {
                VStack(spacing: 10) {
                    EmptyState(symbol: "xmark.bin", text: L("Kaldırmak istediğin uygulamayı seç"))
                    if let m = model.message { Tag(text: m, tint: Dusk.green) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var relatedList: some View {
        let groups = Dictionary(grouping: model.related, by: \.group)
        let order = model.related.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(order, id: \.self) { g in
                    let files = groups[g] ?? []
                    HStack {
                        Text(L(g).uppercased()).font(Dusk.micro).foregroundStyle(Dusk.text3).tracking(0.6)
                        Spacer()
                        Text(Fmt.bytes(files.reduce(0) { $0 + $1.size })).font(Dusk.micro).foregroundStyle(Dusk.text3)
                    }
                    .padding(.horizontal, 10).padding(.top, 10)
                    ForEach(files) { f in fileRow(f) }
                }
            }
            .padding(10)
        }
    }

    private func fileRow(_ f: RelatedFile) -> some View {
        let on = model.relatedSelection.contains(f.id)
        return HStack(spacing: 10) {
            DuskCheck(state: on) { model.relatedSelection.set(f.id, !on) }
            Image(systemName: f.isBundle ? "app.fill" : (FS.isDirectory(f.url.path) ? "folder.fill" : "doc.fill"))
                .foregroundStyle(f.isBundle ? Dusk.coral : Dusk.text3).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: FS.home, with: "~"))
                    .font(Dusk.caption).foregroundStyle(Dusk.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Fmt.bytes(f.size)).font(Dusk.number(12.5, weight: .medium)).foregroundStyle(Dusk.text2)
            IconButton(symbol: "arrow.up.forward.app", help: L("Finder'da göster")) {
                NSWorkspace.shared.activateFileViewerSelecting([f.url])
            }
            .scaleEffect(0.85)
        }
        .rowChrome(selected: on)
        .onTapGesture { model.relatedSelection.set(f.id, !on) }
    }
}
