import AppKit
import ServiceManagement
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case activity, cleanup, disk, apps, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cleanup: L("Temizlik")
        case .disk: L("Büyük Dosyalar")
        case .apps: L("Uygulama Kaldır")
        case .activity: L("Etkinlik")
        case .settings: L("Ayarlar")
        }
    }
    var icon: String {
        switch self {
        case .cleanup: "sparkles"
        case .disk: "square.stack.3d.up.fill"
        case .apps: "xmark.bin.fill"
        case .activity: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
    var tint: Color {
        switch self {
        case .cleanup: Dusk.amber
        case .disk: Dusk.violet
        case .apps: Dusk.coral
        case .activity: Dusk.teal
        case .settings: Dusk.text2
        }
    }
}

/// Owns everything shown in the window; dropped entirely when the window closes so
/// scan results don't linger in memory.
@MainActor
final class WindowModels: ObservableObject {
    @Published var tab: MainTab? = .cleanup
    lazy var cleaner = CleanerModel()
    lazy var disk = DiskModel()
    lazy var apps = AppsModel()
    lazy var activity = ActivityModel()
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?
    private var models: WindowModels?

    func show(_ tab: MainTab) {
        if window == nil {
            let m = WindowModels()
            models = m
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Perch"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = Dusk.darkAppearance
            w.backgroundColor = NSColor(Dusk.night)
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 940, height: 580)
            w.contentViewController = NSHostingController(rootView: MainView(models: m))
            w.setContentSize(NSSize(width: 980, height: 660))
            w.center()
            w.setFrameAutosaveName("PerchMain2")
            w.delegate = self
            window = w
        }
        models?.tab = tab
        // While the window is open Perch behaves like a normal app (Dock icon, ⌘⇥),
        // so it can't get lost behind other windows.
        NSApp.setActivationPolicy(.regular)
        bringToFront()
    }

    func close() {
        window?.performClose(nil)
    }

    /// Rebuilds the SwiftUI tree so every string picks up a language change.
    func reloadContent() {
        guard let window, let models else { return }
        window.contentViewController = NSHostingController(rootView: MainView(models: models))
    }

    /// Re-focuses the window after something else (an admin prompt, a quitting app) took focus.
    func bringToFront() {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            self.window?.contentViewController = nil
            self.window = nil
            self.models = nil
        }
    }
}

struct MainView: View {
    @ObservedObject var models: WindowModels

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $models.tab)
                .layoutPriority(1)
            Rectangle().fill(Dusk.stroke).frame(width: 1)
            Group {
                switch models.tab ?? .cleanup {
                case .cleanup: CleanerView(model: models.cleaner)
                case .disk: DiskView(model: models.disk)
                case .apps: AppsView(model: models.apps)
                case .activity: ActivityView(model: models.activity)
                case .settings: SettingsView()
                }
            }
            // Content takes what's left and can never squeeze the sidebar.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(DuskBackground())
        .foregroundStyle(Dusk.text)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 940, minHeight: 580)
    }
}

private struct Sidebar: View {
    @Binding var selection: MainTab?
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                Text("Perch").font(Dusk.title(20))
            }
            .padding(.top, 46).padding(.bottom, 22).padding(.horizontal, 6)

            ForEach(MainTab.allCases.filter { $0 != .settings }) { tab in
                item(tab)
            }
            Spacer()
            awakeCard
            item(.settings)
        }
        .padding(.horizontal, 12).padding(.bottom, 14)
        .frame(width: 240)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.black.opacity(0.18))
    }

    private func item(_ tab: MainTab) -> some View {
        let on = selection == tab
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selection = tab }
        } label: {
            HStack(spacing: 11) {
                IconBadge(symbol: tab.icon, tint: on ? tab.tint : Dusk.text2, size: 28)
                Text(tab.title).font(.system(size: 13.5, weight: on ? .semibold : .medium, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(on ? Dusk.text : Dusk.text2)
                Spacer()
                if on {
                    Capsule().fill(Dusk.accent).frame(width: 4, height: 16)
                }
            }
            .rowChrome(selected: false)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(on ? Dusk.surfaceHi : .clear))
        }
        .buttonStyle(.plain)
    }

    private var awakeCard: some View {
        DuskCard(padding: 12, radius: 14, tint: awake.isActive ? Dusk.amber : nil) {
            HStack(spacing: 10) {
                Image(systemName: awake.isActive ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(awake.isActive ? Dusk.amber : Dusk.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Uyanık kal")).font(Dusk.heading(12.5))
                    Text(awake.isActive ? L("Açık") : L("Kapalı")).font(Dusk.caption).foregroundStyle(Dusk.text3)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { awake.isActive }, set: { $0 ? awake.toggle() : awake.stop() }))
                    .toggleStyle(PillSwitch())
            }
        }
        .padding(.bottom, 6)
    }
}
