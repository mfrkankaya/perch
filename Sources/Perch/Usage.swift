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
}

/// Reads the locally stored Claude Code / Codex CLI logins and asks each service for the
/// current rate-limit windows. Fetches only when the menu opens (or every 5 min when the
/// menu-bar percentage is enabled). Tokens are never refreshed or written back.
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
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        } catch {
            return (-1, nil)
        }
    }

    // MARK: Claude

    private nonisolated static func claudeCredentials() -> (token: String, plan: String?)? {
        var raw: Data?
        // `security` is already on the item's access list, so this does not trigger a Keychain prompt.
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        if r.status == 0 { raw = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) }
        if raw == nil {
            raw = FileManager.default.contents(atPath: FS.home + "/.claude/.credentials.json")
        }
        guard let raw,
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }

    static func fetchClaude() async -> ProviderUsage {
        guard let cred = await Task.detached(operation: { claudeCredentials() }).value else {
            return ProviderUsage(error: L("Claude Code girişi bulunamadı"))
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (code, json) = await getJSON(req)
        var result = ProviderUsage(plan: cred.plan?.capitalized)
        guard code == 200, let json else {
            result.error = code == 401 ? L("Oturum süresi dolmuş – terminalde `claude` çalıştır") : L("Alınamadı (%d)", code)
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
              let token = tokens["access_token"] as? String else { return nil }
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
