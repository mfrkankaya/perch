import AppKit
import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: ActivityModel
    @State private var confirmForce: ActivityModel.Row?

    var body: some View {
        FadingScroll {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: L("Etkinlik"), subtitle: L("Mac'i şu an en çok ne yoruyor?")) {
                    HStack(spacing: 6) {
                        Circle().fill(Dusk.green).frame(width: 7, height: 7)
                        Text(L("Canlı")).font(Dusk.micro).foregroundStyle(Dusk.text2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Dusk.surfaceHi))
                }
                if model.ready {
                    verdict
                    HStack(alignment: .top, spacing: 14) {
                        column(title: L("İşlemci"), icon: "cpu.fill", tint: Dusk.sky,
                               fill: Dusk.gradient(Dusk.sky, Dusk.teal),
                               total: ActivityModel.percent(model.cpuShare), totalShare: model.cpuShare,
                               caption: L("Mac'in tamamına göre"), rows: model.cpuRows)
                        column(title: L("Bellek"), icon: "memorychip.fill", tint: Dusk.violet,
                               fill: Dusk.gradient(Dusk.violet, Dusk.coral),
                               total: Fmt.bytes(model.system.memUsed), totalShare: model.memShare,
                               caption: L("Toplam %@", Fmt.bytes(model.system.memTotal)), rows: model.memRows)
                    }
                    HStack(spacing: 8) {
                        DuskCheck(state: model.showBackground) { model.showBackground.toggle() }
                        Text(L("Sistem ve arka plan işlemlerini tek tek göster"))
                            .font(Dusk.caption).foregroundStyle(Dusk.text2)
                            .onTapGesture { model.showBackground.toggle() }
                    }
                } else {
                    DuskSpinner(size: 40).frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(28)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog(L("%@ yanıt vermiyor mu? Zorla kapatılsın mı?", confirmForce?.name ?? ""), isPresented: Binding(
            get: { confirmForce != nil }, set: { if !$0 { confirmForce = nil } })) {
            Button(L("Zorla kapat"), role: .destructive) { if let r = confirmForce { model.quit(r, force: true) } }
        } message: {
            Text(L("Kaydedilmemiş değişiklikler kaybolur."))
        }
    }

    private var verdict: some View {
        let v = model.verdict
        return DuskCard(padding: 20, radius: 22, tint: v.color) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(v.color.opacity(0.16)).frame(width: 54, height: 54)
                    Image(systemName: v.icon).font(.system(size: 24, weight: .semibold)).foregroundStyle(v.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.title).font(Dusk.title(20))
                    Text(v.detail).font(Dusk.body).foregroundStyle(Dusk.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private func column(title: String, icon: String, tint: Color, fill: LinearGradient,
                        total: String, totalShare: Double, caption: String,
                        rows: [ActivityModel.Row]) -> some View {
        let maxShare = max(rows.map(\.share).max() ?? 0, 0.0001)
        return DuskCard(padding: 16, radius: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    IconBadge(symbol: icon, tint: tint, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(Dusk.heading(14))
                        Text(caption).font(Dusk.caption).foregroundStyle(Dusk.text3)
                    }
                    Spacer()
                    Text(total).font(Dusk.number(24, weight: .bold)).foregroundStyle(fill)
                        .contentTransition(.numericText())
                }
                DuskBar(value: totalShare, fill: AnyShapeStyle(fill), height: 8)
                    .animation(.easeOut(duration: 0.5), value: totalShare)
                Text(L("en çok kullananlar").uppercased()).font(Dusk.micro).foregroundStyle(Dusk.text3).tracking(0.6)
                    .padding(.top, 4)
                VStack(spacing: 2) {
                    ForEach(rows) { r in
                        ActivityRow(row: r, fill: fill, scale: maxShare,
                                    onQuit: { model.quit(r, force: false) },
                                    onForceQuit: { confirmForce = r })
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let row: ActivityModel.Row
    let fill: LinearGradient
    let scale: Double
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let path = row.bundlePath {
                    AppIconView(path: path, size: 26)
                } else {
                    IconBadge(symbol: row.quittable ? "terminal.fill" : "gearshape.2.fill", tint: Dusk.text3, size: 26)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let d = row.detail { Text(d).font(Dusk.caption).foregroundStyle(Dusk.text3) }
                    Spacer(minLength: 6)
                    Text(row.value).font(Dusk.number(13))
                }
                DuskBar(value: row.share / scale,
                        fill: row.quittable ? AnyShapeStyle(fill) : AnyShapeStyle(Dusk.text3.opacity(0.6)), height: 4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Dusk.surfaceHi : .clear))
        .overlay(alignment: .topTrailing) {
            if row.quittable && hover {
                Button(L("Kapat"), action: onQuit)
                    .buttonStyle(DuskButton(kind: .danger))
                    .padding(.top, 2).padding(.trailing, 4)
                    .help(L("Uygulamadan çık"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if row.quittable {
                Button(L("Kapat"), action: onQuit)
                Button(L("Zorla kapat…"), action: onForceQuit)
            }
            if let path = row.bundlePath {
                Button(L("Finder'da göster")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }
}
