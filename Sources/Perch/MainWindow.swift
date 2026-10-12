import AppKit
import ServiceManagement
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case cleanup, disk, apps, activity, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cleanup: "Temizlik"
        case .disk: "Büyük Dosyalar"
        case .apps: "Uygulama Kaldır"
        case .activity: "Etkinlik"
        case .settings: "Ayarlar"
        }
    }
    var icon: String {
        switch self {
        case .cleanup: "sparkles"
        case .disk: "chart.bar.doc.horizontal"
        case .apps: "trash.square"
        case .activity: "gauge.with.dots.needle.67percent"
        case .settings: "gearshape"
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Perch"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.contentViewController = NSHostingController(rootView: MainView(models: m))
            w.setContentSize(NSSize(width: 920, height: 620))
            w.center()
            w.setFrameAutosaveName("PerchMain")
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
        NavigationSplitView {
            List(MainTab.allCases, selection: $models.tab) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            switch models.tab ?? .cleanup {
            case .cleanup: CleanerView(model: models.cleaner)
            case .disk: DiskView(model: models.disk)
            case .apps: AppsView(model: models.apps)
            case .activity: ActivityView(model: models.activity)
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Keys.copyOnCapture) private var copyOnCapture = true
    @AppStorage(Keys.saveFolder) private var saveFolder = FS.home + "/Desktop"
    @AppStorage(Keys.shelfAutoClose) private var shelfAutoClose = 0
    @AppStorage(Keys.showClaudeInMenuBar) private var showClaude = false
    @AppStorage(Keys.keepDisplayOn) private var keepDisplayOn = true
    @ObservedObject private var lid = LidSleep.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var screenAccess = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Genel") {
                Toggle("Girişte otomatik başlat", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Tam Disk Erişimi") {
                    if FS.hasFullDiskAccess {
                        Label("Verildi", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Sistem Ayarları'nı aç") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
                Toggle("Menü çubuğunda Claude oturum yüzdesini göster", isOn: $showClaude)
                    .onChange(of: showClaude) { _, _ in UsageStore.shared.configureBackgroundPolling() }
            }

            Section("Uyanık kalma") {
                Toggle("Ekranı da açık tut", isOn: $keepDisplayOn)
                    .onChange(of: keepDisplayOn) { _, _ in KeepAwake.shared.reapply() }
                LabeledContent("Kapak kapalı modu") {
                    if lid.passwordless {
                        HStack {
                            Label("Şifresiz", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Button("Kaldır") { lid.removePasswordless() }
                        }
                    } else {
                        Button("Şifresiz kullanımı kur…") { lid.installPasswordless() }
                    }
                }
                Text("Kapak modu `pmset disablesleep` kullanır ve root ister. Şifresiz kurulum, yalnızca bu iki pmset komutuna izin veren bir sudoers kuralı ekler (/etc/sudoers.d/perch). Perch kapanırken ayar geri alınır.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ekran görüntüsü") {
                LabeledContent("Alan / pencere") { HotkeyRecorder(key: Keys.hotkeyArea) }
                LabeledContent("Tam ekran") { HotkeyRecorder(key: Keys.hotkeyScreen) }
                Text("Alan modunda Boşluk tuşu pencere seçimine geçer.").font(.caption).foregroundStyle(.secondary)
                if Hotkey.systemScreenshotShortcutsEnabled {
                    HStack {
                        Label("macOS'in kendi ⇧⌘3 / ⇧⌘4 kısayolları açık ve Perch'ünkünü eziyor. Klavye › Kısayollar › Ekran Görüntüleri'nden kapat.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Aç") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                }
                Toggle("Alındığında panoya kopyala", isOn: $copyOnCapture)
                LabeledContent("Kaydetme klasörü") {
                    HStack {
                        Text(saveFolder.replacingOccurrences(of: FS.home, with: "~")).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Değiştir…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            p.canCreateDirectories = true
                            p.directoryURL = URL(fileURLWithPath: saveFolder)
                            if p.runModal() == .OK, let u = p.url { saveFolder = u.path }
                        }
                    }
                }
                Picker("Yığından otomatik kaldır", selection: $shelfAutoClose) {
                    Text("Asla").tag(0)
                    Text("30 saniye").tag(30)
                    Text("1 dakika").tag(60)
                    Text("5 dakika").tag(300)
                }
                LabeledContent("Ekran kaydı izni") {
                    if screenAccess {
                        Label("Verildi", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Sistem Ayarları'nı aç") {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Perch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Çık") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { screenAccess = CGPreflightScreenCaptureAccess() }
    }
}

struct HotkeyRecorder: View {
    let key: String
    @State private var current: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Kısayola bas…" : (current?.display ?? "Yok"))
                    .frame(minWidth: 90)
                    .monospaced()
            }
            if current != nil && !recording {
                Button {
                    UserDefaults.standard.set("", forKey: key)
                    current = nil
                    HotKeyCenter.shared.reloadFromDefaults()
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .onAppear { current = Hotkey.load(key) }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // esc
            if let hk = Hotkey(event: e) {
                UserDefaults.standard.set(hk.encoded, forKey: key)
                current = hk
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotKeyCenter.shared.reloadFromDefaults()
        }
    }
}
