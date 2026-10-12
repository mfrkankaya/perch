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
        if abs(d.timeIntervalSinceNow) < 10 { return "şimdi" }
        return relativeFormatter.localizedString(for: d, relativeTo: .now)
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)g \(h)sa" }
        if h > 0 { return "\(h)sa \(m)dk" }
        if m > 0 { return "\(m)dk" }
        return "\(s)sn"
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
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
            if Shell.runAsAdmin(full, prompt: "Perch bazı korumalı dosyaları Çöp Kutusu'na taşımak istiyor.") {
                let still = failed.filter { FileManager.default.fileExists(atPath: $0.path) }
                ok += failed.count - still.count
                failed = still
            }
        }
        return (ok, failed)
    }
}

extension View {
    func card() -> some View {
        self.padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}


extension Set {
    mutating func set(_ element: Element, _ on: Bool) {
        if on { insert(element) } else { remove(element) }
    }
}
