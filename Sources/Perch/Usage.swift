import Foundation

struct UsageWindow: Identifiable, Hashable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct ProviderUsage {
    var windows: [UsageWindow] = []
    var plan: String?
    var error: String?
    /// Set when the stored login is missing or rejected (401), so the UI can offer
    /// a one-click "run the CLI" button instead of just telling the user to.
    var needsLogin = false
}

/// Reads the locally stored Claude Code / Codex CLI logins and asks each service for the
/// current rate-limit windows. Fetches only when the menu opens (or every 5 min when the
/// menu-bar percentage is enabled). An expired Claude token is refreshed and written back
/// the same way Claude Code does it; Codex tokens are only read.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var claude: ProviderUsage?
    @Published private(set) var codex: ProviderUsage?
    @Published private(set) var isLoading = false
    @Published private(set) var updatedAt: Date?
    var onUpdate: (() -> Void)?

    private var timer: Timer?

    func refreshIfStale() {
        // While a login is pending, always re-check — the user is likely coming back
        // from the terminal flow and we don't want to show a stale "expired" state.
        if claude?.needsLogin == true || codex?.needsLogin == true { refresh(); return }
        if let u = updatedAt, Date().timeIntervalSince(u) < 60 { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            async let c = Self.fetchClaude()
            async let x = Self.fetchCodex()
            let (cc, xx) = await (c, x)
            claude = cc
            codex = xx
            updatedAt = Date()
            isLoading = false
            onUpdate?()
        }
    }

    func configureBackgroundPolling() {
        timer?.invalidate()
        timer = nil
        guard UserDefaults.standard.bool(forKey: Keys.showClaudeInMenuBar) else {
            onUpdate?()
            return
        }
        let t = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor in UsageStore.shared.refresh() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    // MARK: - Networking

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private static func getJSON(_ req: URLRequest) async -> (Int, [String: Any]?) {
        let (code, json, _) = await send(req)
        return (code, json)
    }

    private static func send(_ req: URLRequest) async -> (Int, [String: Any]?, HTTPURLResponse?) {
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            return (http?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data) as? [String: Any], http)
        } catch {
            return (-1, nil, nil)
        }
    }

    // MARK: Claude

    private nonisolated static let claudeService = "Claude Code-credentials"
    private nonisolated static let claudeFile = FS.home + "/.claude/.credentials.json"

    /// The stored Claude Code login plus where it came from, so a refreshed token can be
    /// written back to the same place.
    private struct ClaudeCredentials {
        var doc: [String: Any]
        var keychainAccount: String?   // nil → came from ~/.claude/.credentials.json
        var oauth: [String: Any] { doc["claudeAiOauth"] as? [String: Any] ?? [:] }
        var token: String? { (oauth["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var refreshToken: String? { (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var plan: String? { oauth["subscriptionType"] as? String }
        /// Seconds until the access token expires (expiresAt is epoch ms); nil when unknown.
        var expiresIn: Double? {
            (oauth["expiresAt"] as? NSNumber).map { $0.doubleValue / 1000 - Date().timeIntervalSince1970 }
        }
        var isExpiring: Bool { (expiresIn ?? .infinity) <= 5 * 60 }
        var isExpired: Bool { (expiresIn ?? .infinity) <= 0 }
    }

    private nonisolated static func claudeCredentials() -> ClaudeCredentials? {
        // `security` is already on the item's access list, so this does not trigger a Keychain prompt.
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", claudeService, "-w"])
        if r.status == 0,
           let data = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ClaudeCredentials(doc: doc, keychainAccount: claudeKeychainAccount())
        }
        guard let data = FileManager.default.contents(atPath: claudeFile),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ClaudeCredentials(doc: doc, keychainAccount: nil)
    }

    private nonisolated static func claudeKeychainAccount() -> String {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", claudeService])
        if let line = r.out.split(separator: "\n").first(where: { $0.contains("\"acct\"<blob>=\"") }),
           let start = line.range(of: "<blob>=\"")?.upperBound, line.hasSuffix("\"") {
            return String(line[start..<line.index(before: line.endIndex)])
        }
        return NSUserName()
    }

    private enum RefreshFailure { case rateLimited, rejected }
    /// The token endpoint rate-limits hard, so after a failed refresh we wait before trying
    /// again instead of hitting it on every menu open (which only extends the limit).
    private static var refreshBlockedUntil: Date?
    private static var lastRefreshFailure: RefreshFailure?

    /// Claude Code's access tokens are short-lived and the CLI only renews them while it is
    /// being used. Like the CLI, trade the refresh token for a new pair and store it back,
    /// so the usage view keeps working between Claude Code sessions.
    private static func refreshClaude(_ cred: ClaudeCredentials) async -> ClaudeCredentials? {
        // The CLI may have rotated the token since we read it; using a stale refresh token would fail.
        if let latest = await Task.detached(operation: { claudeCredentials() }).value,
           latest.token != cred.token, latest.token != nil, !latest.isExpiring {
            return latest
        }
        guard let refreshToken = cred.refreshToken else { lastRefreshFailure = .rejected; return nil }
        if let until = refreshBlockedUntil, until > Date() { return nil }
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
        ])
        let (code, json, http) = await send(req)
        guard code == 200, let json, let access = json["access_token"] as? String, !access.isEmpty else {
            switch code {
            case 429:
                let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
                refreshBlockedUntil = Date().addingTimeInterval(max(wait, 10 * 60))
                lastRefreshFailure = .rateLimited
            case 400, 401, 403:
                // The refresh token itself was refused; only a new login fixes that.
                refreshBlockedUntil = Date().addingTimeInterval(10 * 60)
                lastRefreshFailure = .rejected
            default:
                // Network or server trouble: retry on the next fetch.
                break
            }
            return nil
        }
        refreshBlockedUntil = nil
        lastRefreshFailure = nil

        var updated = cred
        var oauth = cred.oauth
        oauth["accessToken"] = access
        if let rt = json["refresh_token"] as? String, !rt.isEmpty { oauth["refreshToken"] = rt }
        if let secs = (json["expires_in"] as? NSNumber)?.doubleValue {
            oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + secs) * 1000)
        }
        updated.doc["claudeAiOauth"] = oauth
        await Task.detached(operation: { saveClaude(updated) }).value
        return updated
    }

    private nonisolated static func saveClaude(_ cred: ClaudeCredentials) {
        guard let data = try? JSONSerialization.data(withJSONObject: cred.doc) else { return }
        if let account = cred.keychainAccount {
            // Sent over stdin as hex so the token never shows up in the process list.
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(claudeService)\" -X \(hex)\n"
            Shell.run("/usr/bin/security", ["-i"], input: cmd)
        } else {
            try? data.write(to: URL(fileURLWithPath: claudeFile), options: .atomic)
        }
    }

    private static func claudeUsageRequest(_ token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    static func fetchClaude() async -> ProviderUsage {
        guard var cred = await Task.detached(operation: { claudeCredentials() }).value, cred.token != nil else {
            return ProviderUsage(error: L("Claude Code girişi bulunamadı"), needsLogin: true)
        }
        if cred.isExpiring, let fresh = await refreshClaude(cred) { cred = fresh }
        // Still expired means the refresh could not run; the usage call would only fail too.
        if cred.isExpired, lastRefreshFailure == .rateLimited {
            return ProviderUsage(plan: cred.plan?.capitalized,
                                 error: L("Oturum yenilenemedi (çok fazla istek) – birkaç dakika sonra tekrar denenecek"))
        }
        var (code, json) = await getJSON(claudeUsageRequest(cred.token!))
        if code == 401, let fresh = await refreshClaude(cred), let token = fresh.token {
            cred = fresh
            (code, json) = await getJSON(claudeUsageRequest(token))
        }
        var result = ProviderUsage(plan: cred.plan?.capitalized)
        guard code == 200, let json else {
            switch code {
            case 401:
                result.error = L("Oturum süresi dolmuş")
                result.needsLogin = true
            case 429:
                result.error = L("Çok fazla istek – biraz sonra dene")
            default:
                result.error = L("Alınamadı (%d)", code)
            }
            return result
        }
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            for (i, l) in limits.enumerated() {
                guard let pct = (l["percent"] as? NSNumber)?.doubleValue else { continue }
                let kind = l["kind"] as? String ?? "limit"
                var label: String
                switch kind {
                case "session": label = L("Oturum (5 sa)")
                case "weekly_all": label = L("Haftalık")
                case "weekly_scoped": label = L("Haftalık")
                default: label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                if let scope = l["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String {
                    label += " · " + name
                }
                result.windows.append(UsageWindow(id: "\(i)-\(kind)", label: label, percent: pct,
                                                  resetsAt: parseISO(l["resets_at"])))
            }
        } else {
            let keys = [("five_hour", L("Oturum (5 sa)")), ("seven_day", L("Haftalık")),
                        ("seven_day_opus", L("Haftalık · Opus")), ("seven_day_sonnet", L("Haftalık · Sonnet"))]
            for (key, label) in keys {
                guard let w = json[key] as? [String: Any],
                      let pct = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                result.windows.append(UsageWindow(id: key, label: label, percent: pct, resetsAt: parseISO(w["resets_at"])))
            }
        }
        if result.windows.isEmpty { result.error = L("Limit bilgisi yok") }
        return result
    }

    // MARK: Codex

    private nonisolated static func codexCredentials() -> (token: String, account: String?)? {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FS.home + "/.codex"
        guard let data = FileManager.default.contents(atPath: base + "/auth.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    static func fetchCodex() async -> ProviderUsage {
        guard let cred = await Task.detached(operation: { codexCredentials() }).value else {
            return ProviderUsage(error: L("Codex girişi bulunamadı (~/.codex/auth.json)"))
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        if let a = cred.account { req.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (code, json) = await getJSON(req)
        var result = ProviderUsage()
        guard code == 200, let json else {
            result.error = code == 401 ? L("Oturum süresi dolmuş – terminalde `codex` çalıştır") : L("Alınamadı (%d)", code)
            return result
        }
        result.plan = (json["plan_type"] as? String)?.capitalized
        if let rl = json["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl[key] as? [String: Any],
                      let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let secs = (w["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
                var reset: Date?
                if let at = (w["reset_at"] as? NSNumber)?.doubleValue {
                    reset = Date(timeIntervalSince1970: at)
                } else if let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue {
                    reset = Date().addingTimeInterval(after)
                }
                result.windows.append(UsageWindow(id: key, label: windowLabel(secs), percent: pct, resetsAt: reset))
            }
        }
        if result.windows.isEmpty { result.error = L("Limit bilgisi yok") }
        return result
    }

    private static func windowLabel(_ secs: Int) -> String {
        switch secs {
        case 0: return L("Limit")
        case 18000: return L("Oturum (5 sa)")
        case 604800: return L("Haftalık")
        case 2_400_000...2_700_000: return L("Aylık")
        default:
            return secs >= 86400 ? L("%d günlük", secs / 86400) : L("%d saatlik", max(1, secs / 3600))
        }
    }

    private static func parseISO(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
