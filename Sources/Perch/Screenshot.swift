import AppKit
import Carbon
import ImageIO
import SwiftUI

// MARK: - Global hotkeys (Carbon: no Accessibility permission needed)

struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon flags
    var display: String

    static let defaultArea = Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘4")
    static let defaultScreen = Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘3")

    /// macOS's own ⇧⌘3 / ⇧⌘4 win over ours unless they're turned off in Keyboard Shortcuts.
    /// Symbolic hotkey ids: 28 = ⇧⌘3, 30 = ⇧⌘4 (missing entry = enabled).
    static var systemScreenshotShortcutsEnabled: Bool {
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        return ["28", "30"].contains { id in
            ((all[id] as? [String: Any])?["enabled"] as? Bool) ?? true
        }
    }

    var encoded: String { "\(keyCode)|\(modifiers)|\(display)" }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    init?(encoded: String) {
        let p = encoded.split(separator: "|", maxSplits: 2).map(String.init)
        guard p.count == 3, let k = UInt32(p[0]), let m = UInt32(p[1]) else { return nil }
        self.init(keyCode: k, modifiers: m, display: p[2])
    }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        var s = ""
        if f.contains(.control) { m |= UInt32(controlKey); s += "⌃" }
        if f.contains(.option) { m |= UInt32(optionKey); s += "⌥" }
        if f.contains(.shift) { m |= UInt32(shiftKey); s += "⇧" }
        if f.contains(.command) { m |= UInt32(cmdKey); s += "⌘" }
        guard m != 0 else { return nil }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
                                         96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let key = special[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, display: s + key)
    }

    static func load(_ key: String) -> Hotkey? {
        UserDefaults.standard.string(forKey: key).flatMap(Hotkey.init(encoded:))
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) { handlers[id]?() }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func register(_ hk: Hotkey, id: UInt32, _ handler: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5052_4348), id: id) // 'PRCH'
        if RegisterEventHotKey(hk.keyCode, hk.modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        }
    }

    func reloadFromDefaults() {
        installHandler()
        unregisterAll()
        if let a = Hotkey.load(Keys.hotkeyArea) { register(a, id: 1) { Screenshotter.shared.capture(.area) } }
        if let s = Hotkey.load(Keys.hotkeyScreen) { register(s, id: 2) { Screenshotter.shared.capture(.screen) } }
    }
}

// MARK: - Capture

@MainActor
final class Screenshotter {
    static let shared = Screenshotter()
    enum Mode { case area, window, screen }

    let shelf = Shelf()
    private var capturing = false
    let dir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Perch/Shots", isDirectory: true)

    func prepare() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    func capture(_ mode: Mode) {
        guard !capturing else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return
        }
        capturing = true
        // Keep the stack out of the shot: fade it out first, then start capturing.
        let startDelay = shelf.items.isEmpty ? 0.0 : 0.16
        shelf.conceal(true)
        let url = dir.appendingPathComponent("Perch \(Self.nameFormatter.string(from: Date())).png")
        var args = ["-x"]
        switch mode {
        case .area: args += ["-i"]
        case .window: args += ["-iW"]
        case .screen: args += ["-m"]
        }
        args.append(url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = Screenshotter.shared
                    me.capturing = false
                    me.shelf.conceal(false)
                    if FileManager.default.fileExists(atPath: url.path) { me.didCapture(url) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) {
            do { try p.run() } catch {
                self.capturing = false
                self.shelf.conceal(false)
            }
        }
    }

    private func didCapture(_ url: URL) {
        if UserDefaults.standard.bool(forKey: Keys.copyOnCapture) { Self.copy(url) }
        shelf.add(url)
    }

    static func copy(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        pb.writeObjects([item])
    }
}

// MARK: - Floating stack (bottom-left)

struct ShotItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage
    var savedTo: URL?
    static func == (a: ShotItem, b: ShotItem) -> Bool { a.id == b.id && a.savedTo == b.savedTo }
}

@MainActor
final class Shelf: ObservableObject {
    @Published private(set) var items: [ShotItem] = []
    var hovered: UUID?
    /// Where the cards currently are (panel-local, top-left origin) – the only clickable area.
    var contentRect: CGRect = .zero
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?
    private let maxItems = 8
    static let cardWidth: CGFloat = 220
    static let layoutAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)

    func add(_ url: URL) {
        guard let thumb = Self.thumbnail(url) else { return }
        let item = ShotItem(url: url, thumbnail: thumb)
        showPanel()
        withAnimation(Self.layoutAnimation) {
            items.append(item)
            while items.count > maxItems {
                let old = items.removeFirst()
                try? FileManager.default.removeItem(at: old.url)
            }
        }
        scheduleAutoClose(item.id)
    }

    func remove(_ item: ShotItem) {
        withAnimation(Self.layoutAnimation) { items.removeAll { $0.id == item.id } }
        try? FileManager.default.removeItem(at: item.url)
        hideIfEmpty()
    }

    func clear() {
        let old = items
        withAnimation(Self.layoutAnimation) { items.removeAll() }
        old.forEach { try? FileManager.default.removeItem(at: $0.url) }
        hideIfEmpty()
    }

    /// Faded out (not removed) while a screenshot is being taken.
    func conceal(_ hidden: Bool, completion: (() -> Void)? = nil) {
        guard let panel else { completion?(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = hidden ? 0.12 : 0.2
            panel.animator().alphaValue = hidden ? 0 : 1
        }, completionHandler: { completion?() })
    }

    @discardableResult
    func save(_ item: ShotItem) -> URL? {
        let folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: Keys.saveFolder) ?? FS.home + "/Desktop")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = FS.uniqueURL(in: folder, name: item.url.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: item.url, to: dest)) != nil else { return nil }
        markSaved(item, dest)
        return dest
    }

    func saveAs(_ item: ShotItem) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = [.png]
        panel.level = .statusBar + 1
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: item.url, to: dest)) != nil { markSaved(item, dest) }
    }

    private func markSaved(_ item: ShotItem, _ dest: URL) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].savedTo = dest }
    }

    private func scheduleAutoClose(_ id: UUID) {
        let secs = UserDefaults.standard.integer(forKey: Keys.shelfAutoClose)
        guard secs > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs)) { [weak self] in
            guard let self, let item = self.items.first(where: { $0.id == id }) else { return }
            if self.hovered == id { self.scheduleAutoClose(id) } else { self.remove(item) }
        }
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    // MARK: Panel

    /// A fixed, full-height transparent strip on the left edge. It never resizes (resizing
    /// is what made cards slide down from the top); cards stack from the bottom inside it.
    private func showPanel() {
        hideWork?.cancel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        let frame = NSRect(x: vf.minX + 4, y: vf.minY + 4, width: Self.cardWidth + 28, height: vf.height - 8)
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.acceptsMouseMovedEvents = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = FirstMouseHostingView(rootView: ShelfView(shelf: self))
            panel = p
            startTrackingMouse()
        } else if panel?.frame != frame {
            panel?.setFrame(frame, display: true)
        }
        panel?.orderFrontRegardless()
    }

    private func hideIfEmpty() {
        guard items.isEmpty else { return }
        // Let the last card finish sliding out first.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.items.isEmpty else { return }
            self.stopTrackingMouse()
            self.panel?.orderOut(nil)
            self.panel?.contentView = nil
            self.panel = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Clicks only belong to the panel while the pointer is over the cards; everywhere else
    /// in the strip they go straight through to whatever is behind it.
    private func startTrackingMouse() {
        let update: () -> Void = { [weak self] in
            guard let self, let panel = self.panel else { return }
            let r = self.contentRect
            let screenRect = NSRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY,
                                    width: r.width, height: r.height)
            let inside = !r.isEmpty && screenRect.contains(NSEvent.mouseLocation)
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in update() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { e in update(); return e } as Any)
    }

    private func stopTrackingMouse() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ShelfView: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shelf.items.count > 1 {
                Button { shelf.clear() } label: { Label(L("Tümünü kapat"), systemImage: "xmark") }
                    .buttonStyle(DuskButton(kind: .secondary))
                    .background(Capsule().fill(Dusk.night.opacity(0.85)))
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }
            ForEach(shelf.items) { item in
                ShotCard(item: item, shelf: shelf)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .padding(14)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shelf.contentRect = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct ShotCard: View {
    let item: ShotItem
    @ObservedObject var shelf: Shelf
    @State private var hover = false
    @State private var toast: String?

    private var width: CGFloat { 220 }
    private var height: CGFloat {
        let s = item.thumbnail.size
        guard s.width > 0 else { return 120 }
        return min(220, max(70, width * s.height / s.width))
    }

    var body: some View {
        ZStack {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()

            if hover {
                Color.black.opacity(0.38)
                VStack {
                    HStack {
                        if item.savedTo != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .help(L("Kaydedildi"))
                        }
                        Spacer()
                        iconButton("xmark", help: L("Kapat")) { shelf.remove(item) }
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        pill(L("Kopyala"), "doc.on.doc") {
                            Screenshotter.copy(item.url)
                            flash(L("Kopyalandı"))
                        }
                        pill(L("Kaydet"), "square.and.arrow.down") {
                            if shelf.save(item) != nil { flash(L("Kaydedildi")) }
                        }
                        iconButton("ellipsis", help: L("Farklı kaydet…")) { shelf.saveAs(item) }
                    }
                }
                .padding(8)
            }

            if let toast {
                Text(toast)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onHover { h in
            hover = h
            shelf.hovered = h ? item.id : nil
        }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .help(L("Sürükle-bırak · çift tıkla aç"))
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { withAnimation { toast = nil } }
    }

    private func pill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
