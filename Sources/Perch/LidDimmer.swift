import AppKit
import Combine
import IOKit

/// With lid mode on, `disablesleep` keeps the built-in panel lit behind the closed lid.
/// While the lid is closed we hold the built-in display's brightness at 0 and put the
/// remembered value back once it opens. The saved value is persisted so a crash while
/// closed can't leave the screen dark on the next launch.
///
/// Brightness can be raised behind our back (auto-brightness, brightness keys on an
/// external keyboard, display wake, other apps), so while closed we re-check every second.
/// While open with lid mode on, a slow poll catches a missed lid notification.
@MainActor
final class LidDimmer {
    static let shared = LidDimmer()

    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [Any] = []
    private var enabledSub: AnyCancellable?
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0

    func start() {
        guard notifyPort == nil else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let kr = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, type, _ in
            // kIOPMMessageClamshellStateChange
            guard type == 0xE003_4100 else { return }
            MainActor.assumeIsolated { LidDimmer.shared.sync() }
        }, nil, &notifier)
        guard kr == KERN_SUCCESS else { IONotificationPortDestroy(port); return }
        notifyPort = port

        // Lid mode toggled while the lid is already closed.
        enabledSub = LidSleep.shared.$isEnabled.removeDuplicates().sink { _ in
            DispatchQueue.main.async { LidDimmer.shared.sync() }
        }
        // Display wake / reconfiguration can reset the panel's brightness.
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LidDimmer.shared.sync() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LidDimmer.shared.sync() }
        })
        sync()
    }

    func stop() {
        setTimer(0)
        enabledSub = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        restore()
    }

    /// Idempotent: reads the real lid state and brings brightness in line with it.
    private func sync() {
        let closed = Self.isLidClosed()
        let enabled = LidSleep.shared.isEnabled
        if closed && enabled {
            holdDark()
            setTimer(1)
        } else {
            if !closed { restore() }
            setTimer(enabled ? 10 : 0)
        }
    }

    private func holdDark() {
        guard let id = Self.builtinDisplay() else { return }
        let d = UserDefaults.standard
        let current = Brightness.get(id)
        if d.object(forKey: Keys.lidSavedBrightness) == nil, let current, current > 0.001 {
            d.set(Double(current), forKey: Keys.lidSavedBrightness)
        }
        if current.map({ $0 > 0.001 }) ?? true { Brightness.set(id, 0) }
    }

    private func restore() {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.lidSavedBrightness) != nil else { return }
        let value = Float(d.double(forKey: Keys.lidSavedBrightness))
        d.removeObject(forKey: Keys.lidSavedBrightness)
        guard let id = Self.builtinDisplay() else { return }
        Brightness.set(id, value)
        // The panel may still be powering up right after the lid opens; apply once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !Self.isLidClosed() else { return }
            Brightness.set(id, value)
        }
    }

    private func setTimer(_ interval: TimeInterval) {
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = interval
        guard interval > 0 else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { LidDimmer.shared.sync() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }

    static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// Built-in display brightness via the private DisplayServices framework (loaded lazily).
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    static func get(_ id: CGDirectDisplayID) -> Float? {
        var v: Float = 0
        guard let getFn, getFn(id, &v) == 0 else { return nil }
        return v
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setFn else { return false }
        return setFn(id, max(0, min(1, value))) == 0
    }
}
