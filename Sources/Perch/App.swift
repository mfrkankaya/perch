import AppKit
import SwiftUI

@main
enum PerchMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let status = StatusController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Keys.registerDefaults()
        NSApp.mainMenu = Self.makeMainMenu()
        status.install()
        Updater.restoreStateAfterRelaunchIfNeeded()
        Updater.shared.scheduleAutomaticChecks()
        Screenshotter.shared.prepare()
        HotKeyCenter.shared.reloadFromDefaults()
        UsageStore.shared.onUpdate = { [weak status] in status?.refreshButton() }
        UsageStore.shared.configureBackgroundPolling()
        KeepAwake.shared.onChange = { [weak status] in status?.refreshButton() }
        LidDimmer.shared.start()
        // `open -a Perch --args --tab disk` opens a window straight away.
        if let i = CommandLine.arguments.firstIndex(of: "--tab"), i + 1 < CommandLine.arguments.count,
           let tab = MainTab(rawValue: CommandLine.arguments[i + 1]) {
            MainWindowController.shared.show(tab)
        }
    }

    @objc func closeMainWindow(_ sender: Any?) {
        MainWindowController.shared.close()
    }

    /// Shown only while the window is open (regular activation): standard editing and window shortcuts.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func mi(_ t: String, _ a: Selector?, _ k: String) -> NSMenuItem { NSMenuItem(title: t, action: a, keyEquivalent: k) }
        submenu("Perch", [
            mi(L("Perch'ü Gizle"), #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            // ⌘Q only closes the window; Perch keeps living in the menu bar.
            mi(L("Pencereyi Kapat"), #selector(AppDelegate.closeMainWindow(_:)), "q"),
            {
                let quit = mi(L("Perch'ten Tamamen Çık"), #selector(NSApplication.terminate(_:)), "q")
                quit.keyEquivalentModifierMask = [.command, .option]
                return quit
            }(),
        ])
        submenu(L("Düzen"), [
            mi(L("Geri Al"), Selector(("undo:")), "z"),
            mi(L("Yinele"), Selector(("redo:")), "Z"),
            .separator(),
            mi(L("Kes"), #selector(NSText.cut(_:)), "x"),
            mi(L("Kopyala"), #selector(NSText.copy(_:)), "c"),
            mi(L("Yapıştır"), #selector(NSText.paste(_:)), "v"),
            mi(L("Tümünü Seç"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(L("Pencere"), [
            mi(L("Kapat"), #selector(NSWindow.performClose(_:)), "w"),
            mi(L("Küçült"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared.stop()
        LidSleep.shared.restoreOnQuit()
        LidDimmer.shared.stop()
        MouseJiggler.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show(.cleanup)
        return false
    }
}

/// Borderless panel that can take key focus (for Esc) without activating the app.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Menu bar item + a custom floating panel (instead of NSPopover, so the whole surface is ours).
@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    private var item: NSStatusItem!
    private var panel: MenuPanel?
    private var monitors: [Any] = []
    private var lastClose = Date.distantPast

    func install() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        refreshButton()
    }

    func refreshButton() {
        guard let button = item?.button else { return }
        let awake = KeepAwake.shared.isActive || LidSleep.shared.isEnabled
        let img = NSImage(systemSymbolName: awake ? "bird.fill" : "bird", accessibilityDescription: "Perch")
        img?.isTemplate = true
        button.image = img
        if UserDefaults.standard.bool(forKey: Keys.showClaudeInMenuBar),
           let w = UsageStore.shared.claude?.windows.first {
            button.title = " \(Int(w.percent.rounded()))%"
        } else {
            button.title = ""
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if panel != nil { close(); return }
        // The click on the icon itself already closed the panel (resign key) – don't reopen.
        if Date().timeIntervalSince(lastClose) < 0.3 { return }
        open()
    }

    private func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let p = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.appearance = Dusk.darkAppearance
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self

        let anchor = buttonWindow.frame
        let host = FirstMouseHostingView(rootView: MenuView(
            close: { [weak self] in self?.close() },
            onSize: { [weak self] size in self?.resize(to: size, anchor: anchor) }
        ))
        p.contentView = host
        panel = p
        resize(to: host.fittingSize, anchor: anchor)

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil } // esc
            return e
        } as Any)
        UsageStore.shared.refreshIfStale()
        LidSleep.shared.refresh()
    }

    /// Keeps the panel hanging from the menu bar icon, clamped to the screen.
    private func resize(to size: CGSize, anchor: NSRect) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        let top = anchor.minY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        lastClose = Date()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        p.delegate = nil
        p.orderOut(nil)
        p.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
