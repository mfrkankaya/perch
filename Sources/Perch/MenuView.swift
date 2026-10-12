import SwiftUI

struct MenuView: View {
    let close: () -> Void
    let onSize: (CGSize) -> Void
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var lid = LidSleep.shared
    @ObservedObject private var usage = UsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            awakeCard
            usageCard
            captureRow
            toolsGrid
        }
        .padding(14)
        .frame(width: 340)
        .background(
            DuskBackground(stars: true)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Dusk.strokeHi))
        .foregroundStyle(Dusk.text)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            Text("Perch").font(Dusk.title(17))
            Spacer()
            IconButton(symbol: "gearshape.fill", help: L("Ayarlar")) { open(.settings) }
            IconButton(symbol: "power", help: L("Çık")) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Awake

    private var awakeCard: some View {
        DuskCard(padding: 14, radius: 18, tint: awake.isActive ? Dusk.amber : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(awake.isActive ? AnyShapeStyle(Dusk.accent) : AnyShapeStyle(Dusk.surfaceHi))
                            .frame(width: 38, height: 38)
                        Image(systemName: awake.isActive ? "sun.max.fill" : "moon.zzz.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(awake.isActive ? Dusk.ink : Dusk.text2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Uyanık kal")).font(Dusk.heading(15))
                        remaining
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { awake.isActive }, set: { $0 ? awake.toggle() : awake.stop() }))
                        .toggleStyle(PillSwitch())
                }
                HStack(spacing: 4) {
                    ForEach(KeepAwake.presets, id: \.seconds) { p in
                        let selected = awake.isActive && UserDefaults.standard.double(forKey: Keys.lastAwakeDuration) == p.seconds
                        Text(L(p.label))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(selected ? Dusk.ink : Dusk.text2)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(Capsule().fill(selected ? AnyShapeStyle(Dusk.accent) : AnyShapeStyle(Color.black.opacity(0.22))))
                            .contentShape(Capsule())
                            .onTapGesture { awake.start(p.seconds) }
                    }
                }
                Rectangle().fill(Dusk.stroke).frame(height: 1)
                HStack(spacing: 12) {
                    Image(systemName: lid.isEnabled ? "laptopcomputer.slash" : "laptopcomputer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(lid.isEnabled ? Dusk.amber : Dusk.text2)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Kapak kapalıyken çalış")).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(lid.lastError ?? (lid.isEnabled ? L("Uyku tamamen kapalı – çantaya koyarken dikkat") : L("Kapak kapanınca uyumaz")))
                            .font(Dusk.caption)
                            .foregroundStyle(lid.lastError != nil ? Dusk.coral : Dusk.text3)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { lid.isEnabled }, set: { lid.set($0) }))
                        .toggleStyle(PillSwitch())
                }
            }
        }
    }

    @ViewBuilder private var remaining: some View {
        if awake.isActive, let end = awake.endsAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(L("%@ kaldı", Fmt.duration(end.timeIntervalSince(ctx.date))))
                    .font(Dusk.number(11.5, weight: .medium)).foregroundStyle(Dusk.amber)
            }
        } else {
            Text(awake.isActive ? L("Süresiz açık") : L("Kapalı"))
                .font(Dusk.caption).foregroundStyle(awake.isActive ? Dusk.amber : Dusk.text3)
        }
    }

    // MARK: Usage

    private var usageCard: some View {
        DuskCard(padding: 14, radius: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Limitler").uppercased()).font(Dusk.micro).foregroundStyle(Dusk.text3).tracking(0.8)
                    Spacer()
                    if usage.isLoading {
                        DuskSpinner(size: 12)
                    } else if let u = usage.updatedAt {
                        Text(Fmt.relative(u)).font(Dusk.caption).foregroundStyle(Dusk.text3)
                    }
                    Button { usage.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Dusk.text2)
                    }
                    .buttonStyle(.plain).disabled(usage.isLoading)
                }
                provider("Claude", tint: Dusk.orange, fill: Dusk.gradient(Dusk.amber, Dusk.orange), usage.claude)
                Rectangle().fill(Dusk.stroke).frame(height: 1)
                provider("Codex", tint: Dusk.teal, fill: Dusk.gradient(Dusk.teal, Dusk.sky), usage.codex)
            }
        }
    }

    @ViewBuilder
    private func provider(_ name: String, tint: Color, fill: LinearGradient, _ u: ProviderUsage?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint, radius: 4)
                Text(name).font(Dusk.heading(13.5))
                if let plan = u?.plan { Tag(text: plan, tint: tint) }
                Spacer()
            }
            if let u {
                if let err = u.error, u.windows.isEmpty {
                    Text(err).font(Dusk.caption).foregroundStyle(Dusk.text3)
                }
                ForEach(u.windows) { w in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L(w.label)).font(Dusk.caption).foregroundStyle(Dusk.text2)
                            Spacer()
                            if let r = w.resetsAt {
                                Text(Fmt.relative(r)).font(Dusk.caption).foregroundStyle(Dusk.text3)
                            }
                            Text(Fmt.percent(w.percent))
                                .font(Dusk.number(13, weight: .bold))
                                .foregroundStyle(w.percent >= 90 ? Dusk.coral : (w.percent >= 75 ? Dusk.amber : Dusk.text))
                                .frame(minWidth: 38, alignment: .trailing)
                        }
                        DuskBar(value: w.percent / 100,
                                fill: w.percent >= 90 ? AnyShapeStyle(Dusk.coral) : AnyShapeStyle(fill), height: 5)
                    }
                }
            } else {
                DuskBar(value: 0, height: 5)
            }
        }
    }

    // MARK: Capture

    private var captureRow: some View {
        HStack(spacing: 8) {
            captureTile(L("Alan"), "viewfinder", Hotkey.load(Keys.hotkeyArea)?.display, .area)
            captureTile(L("Pencere"), "macwindow", nil, .window)
            captureTile(L("Ekran"), "display", Hotkey.load(Keys.hotkeyScreen)?.display, .screen)
        }
    }

    private func captureTile(_ title: String, _ icon: String, _ shortcut: String?, _ mode: Screenshotter.Mode) -> some View {
        Tile {
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Screenshotter.shared.capture(mode) }
        } content: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Dusk.teal)
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(shortcut ?? " ").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Dusk.text3)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
        }
    }

    // MARK: Tools

    private var toolsGrid: some View {
        let tools: [(MainTab, String)] = [
            (.activity, L("Mac'i en çok yoran uygulamalar")),
            (.cleanup, L("Gereksiz dosyaları temizle")),
            (.disk, L("Büyük dosya ve klasörler")),
            (.apps, L("Uygulama ve verilerini kaldır")),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(tools, id: \.0) { tab, subtitle in
                Tile { open(tab) } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        IconBadge(symbol: tab.icon, tint: tab.tint, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Dusk.text3)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                    .padding(11)
                }
            }
        }
    }

    private func open(_ tab: MainTab) {
        close()
        MainWindowController.shared.show(tab)
    }
}

/// Clickable card surface used in the menu.
private struct Tile<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Dusk.surfaceHi : Dusk.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hover ? Dusk.strokeHi : Dusk.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}
