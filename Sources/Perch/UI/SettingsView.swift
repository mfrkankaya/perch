import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Keys.copyOnCapture) private var copyOnCapture = true
    @AppStorage(Keys.saveFolder) private var saveFolder = FS.home + "/Desktop"
    @AppStorage(Keys.shelfAutoClose) private var shelfAutoClose = 0
    @AppStorage(Keys.showClaudeInMenuBar) private var showClaude = false
    @AppStorage(Keys.keepDisplayOn) private var keepDisplayOn = true
    @ObservedObject private var lid = LidSleep.shared
    @ObservedObject private var jiggler = MouseJiggler.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var language = Loc.choice

    var body: some View {
        FadingScroll {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: L("Ayarlar"), subtitle: "Perch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")") {
                    Button(L("Çık")) { NSApp.terminate(nil) }.buttonStyle(DuskButton(kind: .danger))
                }

                group(L("Genel"), "slider.horizontal.3", Dusk.amber) {
                    row(L("Dil")) {
                        DuskSegmented(selection: $language, options: [
                            (.system, L("Sistem")), (.tr, "Türkçe"), (.en, "English"),
                        ])
                    }
                    row(L("Girişte otomatik başlat")) {
                        Toggle("", isOn: $launchAtLogin).toggleStyle(PillSwitch())
                    }
                    row(L("Menü çubuğunda Claude oturum yüzdesini göster")) {
                        Toggle("", isOn: $showClaude).toggleStyle(PillSwitch())
                    }
                    row(L("Tam Disk Erişimi"), last: true) {
                        permission(FS.hasFullDiskAccess,
                                   url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    }
                }

                group(L("Uyanık kalma"), "sun.max.fill", Dusk.orange) {
                    row(L("Ekranı da açık tut")) {
                        Toggle("", isOn: $keepDisplayOn).toggleStyle(PillSwitch())
                    }
                    row(L("Fareyi hareket ettir (Jiggler)"),
                        note: L("Belirlenen süre boyunca hareketsiz kalındığında fareyi 1 piksel oynatarak Slack/Teams durumunu aktif tutar.")) {
                        Toggle("", isOn: Binding(get: { jiggler.isEnabled }, set: { jiggler.set($0) }))
                            .toggleStyle(PillSwitch())
                    }
                    if jiggler.isEnabled {
                        row(L("Hareketsizlik süresi")) {
                            DuskSegmented(selection: Binding(get: { jiggler.interval }, set: { jiggler.setInterval($0) }),
                                          options: [
                                              (60.0, "1dk"), (180.0, "3dk"), (300.0, "5dk"), (600.0, "10dk"),
                                          ])
                        }
                    }
                    row(L("Kapak kapalı modu"),
                        note: L("Kapak modu `pmset disablesleep` kullanır ve root ister. Şifresiz kurulum, yalnızca bu iki pmset komutuna izin veren bir sudoers kuralı ekler (/etc/sudoers.d/perch). Perch kapanırken ayar geri alınır."),
                        last: true) {
                        if lid.passwordless {
                            HStack(spacing: 8) {
                                Tag(text: L("Şifresiz"), tint: Dusk.green)
                                Button(L("Kaldır")) { lid.removePasswordless() }.buttonStyle(DuskButton(kind: .secondary))
                            }
                        } else {
                            Button(L("Şifresiz kullanımı kur…")) { lid.installPasswordless() }
                                .buttonStyle(DuskButton(kind: .secondary))
                        }
                    }
                }

                group(L("Ekran görüntüsü"), "camera.viewfinder", Dusk.teal) {
                    if Hotkey.systemScreenshotShortcutsEnabled {
                        DuskCard(padding: 10, radius: 12, tint: Dusk.coral) {
                            HStack {
                                Text(L("macOS'in kendi ⇧⌘3 / ⇧⌘4 kısayolları açık ve Perch'ünkünü eziyor. Klavye › Kısayollar › Ekran Görüntüleri'nden kapat."))
                                    .font(Dusk.caption).foregroundStyle(Dusk.text2)
                                Spacer()
                                Button(L("Aç")) {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                                }
                                .buttonStyle(DuskButton(kind: .secondary))
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    row(L("Alan / pencere"), note: L("Alan modunda Boşluk tuşu pencere seçimine geçer.")) {
                        HotkeyRecorder(key: Keys.hotkeyArea)
                    }
                    row(L("Tam ekran")) { HotkeyRecorder(key: Keys.hotkeyScreen) }
                    row(L("Alındığında panoya kopyala")) {
                        Toggle("", isOn: $copyOnCapture).toggleStyle(PillSwitch())
                    }
                    row(L("Kaydetme klasörü")) {
                        HStack(spacing: 8) {
                            Text(saveFolder.replacingOccurrences(of: FS.home, with: "~"))
                                .font(Dusk.caption).foregroundStyle(Dusk.text2)
                                .lineLimit(1).truncationMode(.middle)
                            Button(L("Değiştir…")) { chooseFolder() }.buttonStyle(DuskButton(kind: .secondary))
                        }
                    }
                    row(L("Yığından otomatik kaldır")) {
                        DuskSegmented(selection: $shelfAutoClose, options: [
                            (0, L("Asla")), (30, "30s"), (60, "1m"), (300, "5m"),
                        ])
                    }
                    row(L("Ekran kaydı izni"), last: true) {
                        permission(screenAccess,
                                   url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                                   request: { CGRequestScreenCaptureAccess() })
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { screenAccess = CGPreflightScreenCaptureAccess() }
        .onChange(of: language) { _, c in
            Loc.set(c)
            NSApp.mainMenu = AppDelegate.makeMainMenu()
            UsageStore.shared.refresh()
            DispatchQueue.main.async { MainWindowController.shared.reloadContent() }
        }
        .onChange(of: launchAtLogin) { _, on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        .onChange(of: showClaude) { _, _ in UsageStore.shared.configureBackgroundPolling() }
        .onChange(of: keepDisplayOn) { _, _ in KeepAwake.shared.reapply() }
    }

    private func group<Content: View>(_ title: String, _ icon: String, _ tint: Color,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                IconBadge(symbol: icon, tint: tint, size: 24)
                Text(title).font(Dusk.heading(14))
            }
            DuskCard(padding: 0) {
                VStack(spacing: 0) { content() }
            }
        }
    }

    private func row<Control: View>(_ title: String, note: String? = nil, last: Bool = false,
                                    @ViewBuilder _ control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let note {
                        Text(note).font(Dusk.caption).foregroundStyle(Dusk.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if !last { Rectangle().fill(Dusk.stroke).frame(height: 1).padding(.leading, 16) }
        }
    }

    @ViewBuilder
    private func permission(_ granted: Bool, url: String, request: (() -> Void)? = nil) -> some View {
        if granted {
            Tag(text: L("Verildi"), tint: Dusk.green)
        } else {
            Button(L("Sistem Ayarları'nı aç")) {
                request?()
                NSWorkspace.shared.open(URL(string: url)!)
            }
            .buttonStyle(DuskButton(kind: .primary))
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: saveFolder)
        if p.runModal() == .OK, let u = p.url { saveFolder = u.path }
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
                Text(recording ? L("Kısayola bas…") : (current?.display ?? L("Yok")))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(recording ? Dusk.ink : Dusk.text)
                    .frame(minWidth: 96)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(recording ? AnyShapeStyle(Dusk.accent) : AnyShapeStyle(Color.black.opacity(0.25)))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Dusk.strokeHi))
            }
            .buttonStyle(.plain)
            if current != nil && !recording {
                Button {
                    UserDefaults.standard.set("", forKey: key)
                    current = nil
                    HotKeyCenter.shared.reloadFromDefaults()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Dusk.text3)
                }
                .buttonStyle(.plain)
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
