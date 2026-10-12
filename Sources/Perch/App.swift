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

    func install() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        popover.behavior = .transient
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
        let host = NSHostingController(rootView: MenuView(close: { [weak self] in self?.close() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        UsageStore.shared.refreshIfStale()
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
