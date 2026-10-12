import SwiftUI

struct MenuView: View {
    let close: () -> Void
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var lid = LidSleep.shared
    @ObservedObject private var usage = UsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            awakeSection
            usageSection
            captureSection
            toolsSection
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text(L("Perch")).font(.headline)
            Spacer()
            Button { open(.settings) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help(L("Ayarlar"))
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).help(L("Çık"))
        }
    }

    // MARK: Awake

    private var awakeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(awake.isActive ? Color.orange : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Uyanık kal")).fontWeight(.medium)
                    remaining
                }
                Spacer()
                Toggle("", isOn: Binding(get: { awake.isActive }, set: { $0 ? awake.toggle() : awake.stop() }))
                    .toggleStyle(PillSwitch())
            }
            HStack(spacing: 4) {
                ForEach(KeepAwake.presets, id: \.seconds) { p in
                    let selected = awake.isActive && isCurrent(p.seconds)
                    Button { awake.start(p.seconds) } label: {
                        Text(L(p.label)).font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                            .foregroundStyle(selected ? Color.white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Image(systemName: lid.isEnabled ? "laptopcomputer.slash" : "laptopcomputer")
                    .foregroundStyle(lid.isEnabled ? Color.orange : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Kapak kapalıyken çalış")).fontWeight(.medium)
                    Text(lid.lastError ?? (lid.isEnabled ? L("Uyku tamamen kapalı – çantaya koyarken dikkat") : L("Kapak kapanınca uyumaz")))
                        .font(.caption).foregroundStyle(lid.lastError != nil ? .red : .secondary)
                }
                Spacer()
                if lid.busy { ProgressView().controlSize(.mini) }
                Toggle("", isOn: Binding(get: { lid.isEnabled }, set: { lid.set($0) }))
                    .toggleStyle(PillSwitch())
                    .disabled(lid.busy)
            }
        }
        .card()
    }

    private func isCurrent(_ seconds: TimeInterval) -> Bool {
        UserDefaults.standard.double(forKey: Keys.lastAwakeDuration) == seconds
    }

    @ViewBuilder private var remaining: some View {
        if awake.isActive, let end = awake.endsAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(L("%@ kaldı", Fmt.duration(end.timeIntervalSince(ctx.date)))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            Text(awake.isActive ? L("Süresiz açık") : L("Kapalı")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Limitler")).font(.subheadline.weight(.semibold))
                Spacer()
                if usage.isLoading {
                    ProgressView().controlSize(.mini)
                } else if let u = usage.updatedAt {
                    Text(Fmt.relative(u)).font(.caption2).foregroundStyle(.tertiary)
                }
                Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                    .buttonStyle(.plain).disabled(usage.isLoading)
            }
            provider("Claude", color: Color(red: 0.85, green: 0.47, blue: 0.34), usage.claude)
            provider("Codex", color: Color(red: 0.25, green: 0.55, blue: 0.95), usage.codex)
        }
        .card()
    }

    @ViewBuilder
    private func provider(_ name: String, color: Color, _ u: ProviderUsage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.callout.weight(.medium))
                if let plan = u?.plan {
                    Text(plan).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.18)))
                }
                Spacer()
            }
            if let u {
                if let err = u.error, u.windows.isEmpty {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(u.windows) { w in UsageBar(window: w, color: color) }
            } else {
                Text(L("Yükleniyor…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Capture

    private var captureSection: some View {
        HStack(spacing: 8) {
            captureButton(L("Alan"), "crop", Hotkey.load(Keys.hotkeyArea)?.display, .area)
            captureButton(L("Pencere"), "macwindow", nil, .window)
            captureButton(L("Ekran"), "display", Hotkey.load(Keys.hotkeyScreen)?.display, .screen)
        }
    }

    private func captureButton(_ title: String, _ icon: String, _ shortcut: String?, _ mode: Screenshotter.Mode) -> some View {
        Button {
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Screenshotter.shared.capture(mode) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.caption.weight(.medium))
                Text(shortcut ?? " ").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tools

    private var toolsSection: some View {
        VStack(spacing: 2) {
            toolRow(.activity, L("Mac'i en çok yoran uygulamalar"))
            toolRow(.cleanup, L("Gereksiz dosyaları temizle"))
            toolRow(.disk, L("Büyük dosya ve klasörler"))
            toolRow(.apps, L("Uygulama ve verilerini kaldır"))
        }
    }

    private func toolRow(_ tab: MainTab, _ subtitle: String) -> some View {
        Button { open(tab) } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon).frame(width: 20).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    private func open(_ tab: MainTab) {
        close()
        MainWindowController.shared.show(tab)
    }
}

struct UsageBar: View {
    let window: UsageWindow
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L(window.label)).font(.caption)
                Spacer()
                Text("%\(Int(window.percent.rounded()))").font(.caption.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(barColor).frame(width: max(3, g.size.width * min(1, window.percent / 100)))
                }
            }
            .frame(height: 5)
            if let r = window.resetsAt {
                Text(L("Sıfırlanma: %@", Fmt.relative(r))).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var barColor: Color {
        window.percent >= 90 ? .red : (window.percent >= 75 ? .orange : color)
    }
}

struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hover ? 0.06 : 0))))
                .onHover { hover = $0 }
        }
    }
}

/// Pure-SwiftUI switch. The native NSSwitch ignores the click that activates an inactive
/// popover, so it needed two clicks; a drawn switch handles the first one.
struct PillSwitch: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Capsule()
            .fill(on ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: 34, height: 20)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: on)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? L("Açık") : L("Kapalı"))
    }
}
