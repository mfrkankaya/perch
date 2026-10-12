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
        Screenshotter.shared.prepare()
        HotKeyCenter.shared.reloadFromDefaults()
        UsageStore.shared.onUpdate = { [weak status] in status?.refreshButton() }
        UsageStore.shared.configureBackgroundPolling()
        KeepAwake.shared.onChange = { [weak status] in status?.refreshButton() }
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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show(.cleanup)
        return false
    }
}

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?

    func install() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        // Closed manually on outside clicks: `.transient` also closes as soon as the app activates,
        // which made the menu vanish (or need a second click) when a Perch window was open.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
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
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = item.button else { return }
        // Build the SwiftUI tree only while visible; dropped again on close.
        let host = FirstMouseHostingController(rootView: MenuView(close: { [weak self] in self?.close() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        UsageStore.shared.refreshIfStale()
        LidSleep.shared.refresh()
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        popover.contentViewController = nil
    }
}

/// Hosting controller whose view accepts the click that also activates its window.
final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}
