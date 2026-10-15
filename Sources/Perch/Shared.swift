import SwiftUI
import AppKit

enum Keys {
    static let copyOnCapture = "copyOnCapture"
    static let saveFolder = "saveFolder"
    static let shelfAutoClose = "shelfAutoClose"
    static let showClaudeInMenuBar = "showClaudeInMenuBar"
    static let keepDisplayOn = "keepDisplayOn"
    static let hotkeyArea = "hotkeyArea"
    static let hotkeyScreen = "hotkeyScreen"
    static let lastAwakeDuration = "lastAwakeDuration"
    static let jigglerEnabled = "jigglerEnabled"
    static let jigglerInterval = "jigglerInterval"
    static let updateRelaunchLid = "updateRelaunchLid"
    static let lidSavedBrightness = "lidSavedBrightness"
    static let updateRelaunchAwake = "updateRelaunchAwake"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            copyOnCapture: true,
            saveFolder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path,
            shelfAutoClose: 0,
            showClaudeInMenuBar: false,
            keepDisplayOn: true,
            hotkeyArea: Hotkey.defaultArea.encoded,
            hotkeyScreen: Hotkey.defaultScreen.encoded,
            lastAwakeDuration: 0,
            jigglerEnabled: false,
            jigglerInterval: 300.0,
            autoCheckUpdates: false,
            lastUpdateCheck: 0.0,
        ])
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ d: Date) -> String {
        if abs(d.timeIntervalSinceNow) < 10 { return L("şimdi") }
        relativeFormatter.locale = Loc.locale
        return relativeFormatter.localizedString(for: d, relativeTo: .now)
    }

    /// Turkish puts the sign first (%38), English after (38%).
    static func percent(_ value: Double, decimals: Int = 0) -> String {
        let n = decimals == 0 ? "\(Int(value.rounded()))" : String(format: "%.\(decimals)f", locale: Loc.locale, value)
        return Loc.lang == "tr" ? "%" + n : n + "%"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return L("%dg %dsa", d, h) }
        if h > 0 { return L("%dsa %ddk", h, m) }
        if m > 0 { return L("%ddk", m) }
        return L("%dsn", s)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String], input: String? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let inPipe = input == nil ? nil : Pipe()
        if let inPipe { p.standardInput = inPipe }
        do { try p.run() } catch { return (-1, "") }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell command as root through the standard macOS admin password dialog.
    static func runAsAdmin(_ command: String, prompt: String) -> Bool {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "do shell script \"\(esc(command))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script]).status == 0
    }
}

/// Launches the provider CLIs (Claude Code, Codex) on the user's behalf.
enum CLI {
    /// Finds a CLI through the user's login shell, so Homebrew / ~/.local/bin paths
    /// resolve the same way they do in their own terminal.
    static func path(_ name: String) -> String? {
        let r = Shell.run("/bin/zsh", ["-lc", "command -v \(name) 2>/dev/null"])
        let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !p.isEmpty ? p : nil
    }

    /// Opens Terminal running the CLI. `claude auth login` is what actually starts
    /// the flow: it refreshes a still-valid session in place, and when the refresh
    /// token is dead it drives the browser login. A real TTY is deliberate — headless
    /// (`claude -p`, piped stdin) the CLI neither refreshes nor prompts, and can even
    /// drop the stored login. Perch never reads or writes the credentials itself.
    static func runInTerminal(_ name: String, _ args: [String] = [], note: String) {
        guard let exe = path(name) else {
            presentTerminalError(name)
            return
        }
        let launch = ([exe] + args).map(Shell.quote).joined(separator: " ")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perch-\(name).command")
        let script = """
        #!/bin/zsh -l
        cd "$HOME"
        clear
        echo \(Shell.quote(note))
        echo
        exec \(launch)
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            presentTerminalError(name)
        }
    }

    private static func presentTerminalError(_ name: String) {
        let a = NSAlert()
        a.messageText = L("`%@` bulunamadı", name)
        a.informativeText = L("Terminalde `%@` komutunu çalıştırıp tarayıcıdan giriş yapabilirsin.", name)
        a.addButton(withTitle: L("Tamam"))
        a.runModal()
    }
}

enum FS {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// TCC.db is only readable with Full Disk Access; without it, walking protected
    /// folders pops a privacy prompt per location, so scanners skip them instead.
    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static let protectedPaths: Set<String> = [
        "/Library/Containers", "/Library/Group Containers", "/Library/Mail", "/Library/Messages",
        "/Library/Safari", "/Library/Cookies", "/Library/HomeKit", "/Library/IdentityServices",
        "/Library/Metadata/CoreSpotlight", "/Library/Suggestions", "/Library/Calendars",
        "/Library/Reminders", "/Library/Application Support/AddressBook", "/Library/Application Support/CallHistoryDB",
        "/Library/Application Support/com.apple.TCC", "/Library/Biome", "/Library/Accounts",
    ].reduce(into: Set<String>()) { $0.insert(home + $1) }

    static func isProtected(_ path: String) -> Bool {
        protectedPaths.contains(path) || path.hasSuffix(".photoslibrary") || path.hasSuffix(".photolibrary")
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & 0o170000) == 0o040000
    }

    /// Disk space actually used (allocated blocks), not logical size.
    static func allocatedSize(_ path: String, isCancelled: () -> Bool = { false }) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & 0o170000) != 0o040000 { return Int64(st.st_blocks) * 512 }
        var total: Int64 = 0
        var n = 0
        walk(path) { ent, _ in
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_F || info == FTS_SL || info == FTS_DEFAULT {
                total += Int64(ent.pointee.fts_statp.pointee.st_blocks) * 512
            }
            n += 1
            return n % 2048 != 0 || !isCancelled()
        }
        return total
    }

    /// Fast physical directory walk using fts(3). `visit` returns false to stop.
    static func walk(_ path: String, _ visit: (UnsafeMutablePointer<FTSENT>, UnsafeMutablePointer<FTS>) -> Bool) {
        guard let cpath = strdup(path) else { return }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            if !visit(ent, fts) { break }
        }
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }

    /// Moves to Trash; items we can't touch fall back to an admin move into the user's Trash.
    static func recycle(_ urls: [URL], adminFallback: Bool) async -> (ok: Int, failed: [URL]) {
        var failed: [URL] = []
        var ok = 0
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                ok += 1
            } catch {
                if FileManager.default.fileExists(atPath: url.path) { failed.append(url) } else { ok += 1 }
            }
        }
        if adminFallback, !failed.isEmpty {
            let trash = home + "/.Trash/"
            let stamp = Int(Date().timeIntervalSince1970)
            let cmd = failed.map { u in
                "/bin/mv -f \(Shell.quote(u.path)) \(Shell.quote(trash + u.lastPathComponent + " \(stamp)"))"
            }.joined(separator: " ; ")
            let user = NSUserName()
            let full = cmd + " ; /usr/sbin/chown -R \(Shell.quote(user)) \(Shell.quote(trash)) 2>/dev/null; true"
            if Shell.runAsAdmin(full, prompt: L("Perch bazı korumalı dosyaları Çöp Kutusu'na taşımak istiyor.")) {
                let still = failed.filter { FileManager.default.fileExists(atPath: $0.path) }
                ok += failed.count - still.count
                failed = still
            }
        }
        return (ok, failed)
    }
}



extension Set {
    mutating func set(_ element: Element, _ on: Bool) {
        if on { insert(element) } else { remove(element) }
    }
}
