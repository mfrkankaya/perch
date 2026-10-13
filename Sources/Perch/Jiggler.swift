import AppKit
import CoreGraphics

@MainActor
final class MouseJiggler: ObservableObject {
    static let shared = MouseJiggler()

    static let intervals: [(label: String, seconds: TimeInterval)] = [
        ("1dk", 60), ("3dk", 180), ("5dk", 300), ("10dk", 600)
    ]

    @Published private(set) var isEnabled = false
    @Published var interval: TimeInterval = 300 {
        didSet {
            UserDefaults.standard.set(interval, forKey: Keys.jigglerInterval)
            onChange?()
        }
    }
    var onChange: (() -> Void)?

    private var timer: Timer?

    init() {
        let savedInterval = UserDefaults.standard.double(forKey: Keys.jigglerInterval)
        if savedInterval > 0 {
            self.interval = savedInterval
        } else {
            self.interval = 300
        }
        let saved = UserDefaults.standard.bool(forKey: Keys.jigglerEnabled)
        if saved {
            start()
        }
    }

    func set(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Keys.jigglerEnabled)
        if on {
            start()
        } else {
            stop()
        }
        onChange?()
    }

    func setInterval(_ newInterval: TimeInterval) {
        interval = newInterval
    }

    func start() {
        timer?.invalidate()
        isEnabled = true
        // Check idle state every 2 seconds
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndNudge()
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        onChange?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isEnabled = false
        onChange?()
    }

    private func checkAndNudge() {
        guard isEnabled else { return }
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)

        // Only nudge if the user has been idle for at least the chosen interval
        guard idle >= interval else { return }

        nudge()
    }

    private func nudge() {
        guard let event = CGEvent(source: nil) else { return }
        let currentPos = event.location

        let screenWidth = NSScreen.main?.frame.width ?? 1920
        // 1px micro-nudge
        let delta: CGFloat = (currentPos.x + 1 > screenWidth - 2) ? -1 : 1
        let target = CGPoint(x: currentPos.x + delta, y: currentPos.y)

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(target)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let backEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: currentPos, mouseButton: .left) {
                backEvent.post(tap: .cghidEventTap)
            }
            CGWarpMouseCursorPosition(currentPos)
        }
    }
}
