import AppKit
import IOKit.pwr_mgt

/// Amphetamine-style "stay awake" using a power assertion. Zero cost while idle:
/// one assertion + at most one one-shot timer.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isActive = false
    @Published private(set) var endsAt: Date?
    var onChange: (() -> Void)?

    private var assertionID: IOPMAssertionID = 0
    private var expiry: Timer?

    static let presets: [(label: String, seconds: TimeInterval)] = [
        ("∞", 0), ("15dk", 900), ("1sa", 3600), ("2sa", 7200), ("4sa", 14400), ("8sa", 28800),
    ]

    func toggle() {
        if isActive { stop() } else { start(UserDefaults.standard.double(forKey: Keys.lastAwakeDuration)) }
    }

    /// seconds == 0 means indefinitely.
    func start(_ seconds: TimeInterval) {
        releaseAssertion()
        UserDefaults.standard.set(seconds, forKey: Keys.lastAwakeDuration)
        let displayOn = UserDefaults.standard.bool(forKey: Keys.keepDisplayOn)
        let type = (displayOn ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep") as CFString
        let ok = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Perch – uyanık kal" as CFString, &assertionID)
        guard ok == kIOReturnSuccess else { return }
        isActive = true
        expiry?.invalidate()
        if seconds > 0 {
            endsAt = Date().addingTimeInterval(seconds)
            let t = Timer(timeInterval: seconds, repeats: false) { _ in
                Task { @MainActor in KeepAwake.shared.stop() }
            }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            expiry = t
        } else {
            endsAt = nil
        }
        onChange?()
    }

    func stop() {
        releaseAssertion()
        expiry?.invalidate()
        expiry = nil
        endsAt = nil
        if isActive {
            isActive = false
            onChange?()
        }
    }

    /// Re-applies when the display preference changes.
    func reapply() {
        guard isActive else { return }
        start(endsAt.map { max(1, $0.timeIntervalSinceNow) } ?? 0)
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}

/// Keeps the Mac running with the lid closed (no external display needed) by toggling
/// `pmset disablesleep`. Requires root: either the admin dialog every time, or a one-time
/// sudoers rule scoped to exactly these two pmset commands.
@MainActor
final class LidSleep: ObservableObject {
    static let shared = LidSleep()

    @Published private(set) var isEnabled = false
    @Published private(set) var busy = false
    @Published private(set) var passwordless = false
    @Published var lastError: String?

    private var enabledByUs = false
    nonisolated static let sudoersPath = "/etc/sudoers.d/perch"

    init() {
        isEnabled = Self.readState()
        passwordless = FileManager.default.fileExists(atPath: Self.sudoersPath)
    }

    nonisolated static func readState() -> Bool {
        let out = Shell.run("/usr/bin/pmset", ["-g"]).out
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
        return false
    }

    func set(_ on: Bool) {
        guard !busy else { return }
        busy = true
        lastError = nil
        let pw = passwordless
        Task.detached {
            let ok = Self.apply(on, passwordless: pw)
            let state = Self.readState()
            await MainActor.run {
                let me = LidSleep.shared
                me.busy = false
                me.isEnabled = state
                if on && state { me.enabledByUs = true }
                if !ok { me.lastError = "Değişiklik uygulanamadı" }
                KeepAwake.shared.onChange?()
            }
        }
    }

    nonisolated static func apply(_ on: Bool, passwordless: Bool) -> Bool {
        let arg = on ? "1" : "0"
        if passwordless,
           Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", arg]).status == 0 {
            return true
        }
        return Shell.runAsAdmin("/usr/bin/pmset -a disablesleep \(arg)",
                                prompt: "Perch, kapak kapalıyken uyumayı \(on ? "kapatmak" : "geri açmak") istiyor.")
    }

    func installPasswordless() {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let tmp = "/tmp/perch.sudoers.\(getpid())"
        let cmd = "printf '%s\\n' \(Shell.quote(rule)) > \(tmp) && /usr/sbin/visudo -cf \(tmp) && /usr/bin/install -m 0440 -o root -g wheel \(tmp) \(Self.sudoersPath); rm -f \(tmp)"
        Task.detached {
            _ = Shell.runAsAdmin(cmd, prompt: "Perch, kapak modu için şifresiz pmset izni kurmak istiyor.")
            let exists = FileManager.default.fileExists(atPath: Self.sudoersPath)
            await MainActor.run { LidSleep.shared.passwordless = exists }
        }
    }

    func removePasswordless() {
        Task.detached {
            _ = Shell.runAsAdmin("/bin/rm -f \(Self.sudoersPath)", prompt: "Perch şifresiz pmset iznini kaldırmak istiyor.")
            let exists = FileManager.default.fileExists(atPath: Self.sudoersPath)
            await MainActor.run { LidSleep.shared.passwordless = exists }
        }
    }

    /// Never leave the machine unable to sleep after Perch exits.
    func restoreOnQuit() {
        guard enabledByUs, isEnabled else { return }
        _ = Self.apply(false, passwordless: passwordless)
    }
}
