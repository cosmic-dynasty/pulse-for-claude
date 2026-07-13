// Pulse for Claude
// A tiny menu bar meter for your Claude plan usage.
// Built with Claude by Ant the AI Guy (Everyday AI Club).
// License: MIT

import AppKit
import Security
import ServiceManagement

let APP_NAME = "Pulse for Claude"
let APP_VERSION = "1.0.9"
let USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
let TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
let COST_URL = "https://api.anthropic.com/v1/organizations/cost_report"
let OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
let OAUTH_BETA = "oauth-2025-04-20"
let USER_AGENT = "claude-cli/2.1.0 (external, cli)"
let CC_KEYCHAIN_SERVICE = "Claude Code-credentials"
let PULSE_KEYCHAIN_SERVICE = "club.everydayai.pulse"
// Pulse's OWN keychain item. Because Pulse creates it, Pulse can read and
// write it with no macOS permission prompt, ever. The Claude Code item above
// is only read once, to seed this one.
let PULSE_CRED_SERVICE = "Pulse for Claude-credentials"
let CRED_FILE = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
let PROJECTS_DIR = NSString(string: "~/.claude/projects").expandingTildeInPath
let RETRY_DELAYS: [TimeInterval] = [2, 5, 15]
let USAGE_CACHE_TTL: TimeInterval = 45

// MARK: - Small helpers

func iso8601Date(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

func compactTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1_000_000_000) }
    if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
    if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
    return "\(n)"
}

func timeLeftString(until date: Date) -> String {
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "now" }
    let days = s / 86400
    let hours = (s % 86400) / 3600
    let mins = (s % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

func nextMonthResetLabel() -> String {
    let calendar = Calendar.current
    let now = Date()
    let comps = calendar.dateComponents([.year, .month], from: now)
    guard let startOfThisMonth = calendar.date(from: comps) else { return "" }
    guard let startOfNextMonth = calendar.date(byAdding: .month, value: 1, to: startOfThisMonth) else { return "" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: startOfNextMonth)
}

// Turns an optional into a JSONSerialization-safe value, NSNull when nil,
// so status.json always has every key with a sensible null instead of
// crashing or omitting the key.
func jsonValue<T>(_ v: T?) -> Any {
    if let v = v { return v }
    return NSNull()
}

func relativeAgeString(_ d: Date) -> String {
    let age = Int(Date().timeIntervalSince(d))
    if age < 60 { return "just now" }
    if age < 3600 {
        let mins = age / 60
        return "\(mins)m ago"
    }
    let hours = age / 3600
    let mins = (age % 3600) / 60
    return "\(hours)h \(mins)m ago"
}

func thresholdColor(_ pct: Double) -> NSColor {
    if pct >= 85 { return .systemRed }
    if pct >= 60 { return .systemOrange }
    return .systemGreen
}

func prettyModelName(_ raw: String) -> String {
    // claude-opus-4-7 -> Opus 4.7, claude-haiku-4-5-20251001 -> Haiku 4.5, claude-fable-5 -> Fable 5
    var parts = raw.split(separator: "-").map(String.init)
    guard parts.count >= 2, parts.first == "claude" else { return raw }
    parts.removeFirst()
    let family = parts.removeFirst().capitalized
    let nums = parts.filter { $0.count < 8 && Int($0) != nil }
    if nums.isEmpty { return family }
    return family + " " + nums.joined(separator: ".")
}

func prettyBucketLabel(_ key: String) -> String {
    let known: [String: String] = [
        "five_hour": "5-hour limit",
        "seven_day": "Weekly · all models",
        "seven_day_sonnet": "Weekly · Sonnet only",
        "seven_day_opus": "Weekly · Opus",
        "seven_day_fable": "Weekly · Fable",
        "seven_day_haiku": "Weekly · Haiku",
        "seven_day_cowork": "Weekly · Cowork",
        "seven_day_oauth_apps": "Weekly · connected apps",
    ]
    if let label = known[key] { return label }
    if key.hasPrefix("seven_day_") {
        let rest = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ")
        return "Weekly · " + rest.capitalized
    }
    return key.replacingOccurrences(of: "_", with: " ").capitalized
}

// MARK: - Keychain helpers

func keychainRead(service: String) -> (data: Data, account: String)? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
          let dict = item as? [String: Any],
          let data = dict[kSecValueData as String] as? Data else { return nil }
    let account = dict[kSecAttrAccount as String] as? String ?? ""
    return (data, account)
}

@discardableResult
func keychainWrite(service: String, account: String, data: Data) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
        var add = query
        add[kSecValueData as String] = data
        status = SecItemAdd(add as CFDictionary, nil)
    }
    return status == errSecSuccess
}

func keychainDelete(service: String, account: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
}

// MARK: - Data models

struct UsageBucket {
    let key: String
    let label: String
    let utilization: Double
    let resetsAt: Date?
    let severity: String?
    let isActive: Bool
}

struct ExtraUsage {
    let usedCents: Double
    let limitCents: Double
    let currency: String
    let percent: Double?
    let severity: String?
    let balanceCents: Double?
}

struct UsageSnapshot {
    let buckets: [UsageBucket]
    let extra: ExtraUsage?
    let fetchedAt: Date

    func bucket(_ key: String) -> UsageBucket? {
        return buckets.first { $0.key == key }
    }
    var maxBucket: UsageBucket? {
        return buckets.max { $0.utilization < $1.utilization }
    }
}

struct ModelStat {
    let name: String
    var tokens7d: Int = 0
    var tokensToday: Int = 0
}

enum PulseError: Error, CustomStringConvertible {
    case noCredentials
    case loginExpired
    case network(String)
    case rateLimited
    case httpError(Int)

    var description: String {
        switch self {
        case .noCredentials: return "No Claude login found"
        case .loginExpired: return "Claude login expired"
        case .network(let m): return m
        case .rateLimited: return "Rate limited, showing last known usage"
        case .httpError(let code): return "HTTP error \(code)"
        }
    }

    var isTransient: Bool {
        switch self {
        case .network, .httpError:
            return true
        case .noCredentials, .loginExpired, .rateLimited:
            return false
        }
    }
}

// MARK: - Credentials

// THE OWNERSHIP FIX. Pulse keeps its OWN keychain item (PULSE_CRED_SERVICE).
// An app can always read and write a keychain item it created, with no macOS
// permission prompt. Claude Code's item is read exactly once, to seed ours,
// which is the only time the user ever sees the keychain dialog. After that
// every read, refresh, and write happens against our own item, so the prompts
// stop completely.
//
// All token state lives behind one serial queue, so only one network refresh
// can ever be in flight (kills the double-spend 404 race), and the freshest
// token is held in memory as the source of truth.
final class Credentials {
    private let queue = DispatchQueue(label: "club.everydayai.pulse.token")
    private var accessToken: String = ""
    private var refreshToken: String = ""
    private var expiresAt: Double = 0
    private var loadedOnce = false
    private var ownItemAccess = "" // access token currently stored in our own item

    private var isExpiredLocked: Bool {
        // treat as expired 90s early so we never send a token that dies mid-flight
        return Date().timeIntervalSince1970 * 1000 > (expiresAt - 90_000)
    }

    private func readOAuth(service: String) -> (at: String, rt: String, exp: Double)? {
        guard let kc = keychainRead(service: service),
              let json = (try? JSONSerialization.jsonObject(with: kc.data)) as? [String: Any],
              let o = json["claudeAiOauth"] as? [String: Any],
              let at = o["accessToken"] as? String,
              let rt = o["refreshToken"] as? String else { return nil }
        return (at, rt, (o["expiresAt"] as? NSNumber)?.doubleValue ?? 0)
    }

    private func readFileOAuth() -> (at: String, rt: String, exp: Double)? {
        guard let data = FileManager.default.contents(atPath: CRED_FILE),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let o = json["claudeAiOauth"] as? [String: Any],
              let at = o["accessToken"] as? String,
              let rt = o["refreshToken"] as? String else { return nil }
        return (at, rt, (o["expiresAt"] as? NSNumber)?.doubleValue ?? 0)
    }

    private func adopt(_ t: (at: String, rt: String, exp: Double)?, orNewer: Bool) {
        guard let t = t else { return }
        let fresher = orNewer ? (t.exp > expiresAt) : (t.exp >= expiresAt)
        if accessToken.isEmpty || fresher {
            accessToken = t.at; refreshToken = t.rt; expiresAt = t.exp
        }
    }

    // Loads the freshest usable token. Our OWN item is always checked (free, no
    // prompt). Claude Code's item and the file are consulted ONLY when allowed
    // and only when we still lack a usable token, so in steady state the
    // keychain dialog never appears.
    private func loadLocked(allowSeed: Bool) {
        // FILE first: reading a file never raises a keychain dialog. Pulse keeps
        // this file current on every refresh, so in normal use the keychain is
        // never touched and the password box never appears, even after updates.
        adopt(readFileOAuth(), orNewer: false)
        // Only fall back to the keychain when the file cannot help (first run on
        // a machine where Claude Code stored its login only in the keychain).
        if allowSeed && (accessToken.isEmpty || isExpiredLocked) {
            adopt(readOAuth(service: CC_KEYCHAIN_SERVICE), orNewer: true)
        }
        loadedOnce = true
    }

    // Makes sure the prompt-free file holds the current token (seeding it from
    // the keychain on first run), so later loads are file-only and silent.
    private func persistFileLocked() {
        if !accessToken.isEmpty && (readFileOAuth()?.at ?? "") != accessToken { writeBackLocked() }
    }

    // The one entry point. Returns a currently-valid access token, refreshing
    // at most once. Serialized so concurrent callers can never double-refresh.
    func validAccessToken() -> Result<String, PulseError> {
        return queue.sync {
            if !loadedOnce || accessToken.isEmpty { loadLocked(allowSeed: true) }
            if accessToken.isEmpty { return .failure(.noCredentials) }
            if !isExpiredLocked { persistFileLocked(); return .success(accessToken) }
            return refreshLocked()
        }
    }

    // Forces a refresh even if the in-memory token looks valid. Used when a
    // usage call is rejected with 401 despite a token we believed was good.
    func forceRefresh() -> Result<String, PulseError> {
        return queue.sync { return refreshLocked() }
    }

    // MUST be called on `queue`. Single-flight refresh. Tries our own token
    // first (no prompt); only falls back to seeding from Claude Code's item if
    // ours is gone, which is the lone case that can surface a prompt.
    private func refreshLocked() -> Result<String, PulseError> {
        loadLocked(allowSeed: false)
        if !accessToken.isEmpty && !isExpiredLocked { return .success(accessToken) }
        if refreshToken.isEmpty {
            // Genuine first run only: the file has never held a token at all.
            // This is the one legitimate case for reading Claude Code's
            // keychain item, so it is also the one case that may prompt.
            loadLocked(allowSeed: true)
            if !accessToken.isEmpty && !isExpiredLocked { return .success(accessToken) }
            if refreshToken.isEmpty { return .failure(.noCredentials) }
        }

        switch postRefresh(refreshToken) {
        case .success(let t):
            accessToken = t.access
            refreshToken = t.refresh
            expiresAt = t.exp
            writeBackLocked()
            return .success(accessToken)
        case .failure(let e):
            // Our refresh token was rejected, most likely Claude Code CLI
            // refreshed the same shared token first (a race around sleep/
            // wake or a concurrent CLI session) and ours is now stale.
            // Re-seed from Claude Code's keychain item exactly once and
            // retry, rather than immediately surfacing loginExpired and
            // making the user click Reconnect. This differs from the old
            // per-load re-seed (removed in 1.0.2) that caused a recurring
            // wake prompt: that one fired on every expired-looking load,
            // this one fires only after a real rejection, at most once
            // per refresh attempt.
            let before = refreshToken
            loadLocked(allowSeed: true)
            if refreshToken != before && !refreshToken.isEmpty {
                switch postRefresh(refreshToken) {
                case .success(let t):
                    accessToken = t.access
                    refreshToken = t.refresh
                    expiresAt = t.exp
                    writeBackLocked()
                    return .success(accessToken)
                case .failure(let e2):
                    return .failure(e2)
                }
            }
            return .failure(e)
        }
    }

    private struct NewToken { let access: String; let refresh: String; let exp: Double }

    private func postRefresh(_ rt: String) -> Result<NewToken, PulseError> {
        var req = URLRequest(url: URL(string: TOKEN_URL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(USER_AGENT, forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": OAUTH_CLIENT_ID,
        ])
        req.timeoutInterval = 20

        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: req) { d, r, e in result = (d, r, e); sem.signal() }.resume()
        sem.wait()

        if let e = result.2 { return .failure(.network(e.localizedDescription)) }
        guard let http = result.1 as? HTTPURLResponse, let data = result.0 else {
            return .failure(.network("No response"))
        }
        guard http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newAccess = json["access_token"] as? String else {
            // 4xx here means the refresh token is gone or already spent.
            return .failure(.loginExpired)
        }
        let newRefresh = (json["refresh_token"] as? String) ?? rt
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let exp = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        return .success(NewToken(access: newAccess, refresh: newRefresh, exp: exp))
    }

    // Saves the current token to the file Pulse reads (~/.claude/.credentials.json).
    // Writing a file never raises a keychain dialog, and Pulse reads the file
    // first, so this keeps the app prompt-free. It preserves any other keys
    // already in the file. MUST be called on `queue`.
    private func writeBackLocked() {
        var json: [String: Any] = [:]
        if let data0 = FileManager.default.contents(atPath: CRED_FILE),
           let existing = (try? JSONSerialization.jsonObject(with: data0)) as? [String: Any] {
            json = existing
        }
        var oauth = (json["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAt
        json["claudeAiOauth"] = oauth
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            let url = URL(fileURLWithPath: CRED_FILE)
            if (try? data.write(to: url, options: .atomic)) == nil { try? data.write(to: url) }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CRED_FILE)
        }
    }

    // Runs Claude Code's own sign-in (the correct, official flow) to mint a
    // fresh login, then copies it into the file Pulse reads. This is what the
    // Reconnect button and a failed Refresh call invoke. Returns true on a
    // verifiable fresh token. Safe to call off the main thread.
    func reconnectViaClaudeCLI() -> Bool {
        let home = NSHomeDirectory()
        let candidates = [home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]
        let claude = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let claudeBin = claude else { return false }
        let credPath = home + "/.claude/.credentials.json"
        // 1) sign in (opens the browser, completes via the existing claude.com
        //    session). 2) copy the fresh login from the keychain into the file,
        //    using the `security` tool, which is already trusted for that item,
        //    so no dialog appears.
        let script = "\"\(claudeBin)\" auth login < /dev/null > /dev/null 2>&1; "
            + "/usr/bin/security find-generic-password -s 'Claude Code-credentials' -w > \"\(credPath).pulsetmp\" 2>/dev/null "
            + "&& /bin/mv \"\(credPath).pulsetmp\" \"\(credPath)\" && /bin/chmod 600 \"\(credPath)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", script]
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return queue.sync {
            accessToken = ""; expiresAt = 0; loadedOnce = false
            loadLocked(allowSeed: true)
            return !accessToken.isEmpty && !isExpiredLocked
        }
    }
}

// MARK: - Usage fetcher (the official numbers, same feed the Claude app shows)

final class UsageFetcher {
    let credentials = Credentials()

    func fetch(completion: @escaping (Result<UsageSnapshot, PulseError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSync())
        }
    }

    private func fetchSync() -> Result<UsageSnapshot, PulseError> {
        let tokenResult = credentials.validAccessToken()
        guard case .success(let token) = tokenResult else {
            if case .failure(let e) = tokenResult { return .failure(e) }
            return .failure(.loginExpired)
        }
        switch request(token: token) {
        case .success(let snap):
            return .success(snap)
        case .failure(.loginExpired):
            // Token was rejected despite looking valid. Force exactly one
            // refresh and retry; if that also fails, surface login expired.
            let retry = credentials.forceRefresh()
            guard case .success(let token2) = retry else {
                if case .failure(let e) = retry { return .failure(e) }
                return .failure(.loginExpired)
            }
            return request(token: token2)
        case .failure(let other):
            return .failure(other)
        }
    }

    private func request(token: String) -> Result<UsageSnapshot, PulseError> {
        var req = URLRequest(url: URL(string: USAGE_URL)!)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue(OAUTH_BETA, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(USER_AGENT, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: req) { d, r, e in
            result = (d, r, e)
            sem.signal()
        }.resume()
        sem.wait()

        if let e = result.2 { return .failure(.network(e.localizedDescription)) }
        guard let http = result.1 as? HTTPURLResponse, let data = result.0 else {
            return .failure(.network("No response"))
        }
        if http.statusCode == 401 || http.statusCode == 403 { return .failure(.loginExpired) }
        if http.statusCode == 429 { return .failure(.rateLimited) }
        guard http.statusCode == 200 else { return .failure(.httpError(http.statusCode)) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.network("Bad usage response"))
        }
        return .success(parse(json))
    }

    // Bucket key for one entry of the new top-level "limits" array. Maps each
    // "kind" to the same stable keys the old per-object fields used, so saved
    // icon preferences (which reference these keys) keep working.
    private func limitBucketKey(_ entry: [String: Any]) -> String {
        let kind = (entry["kind"] as? String) ?? "unknown"
        switch kind {
        case "session":
            return "five_hour"
        case "weekly_all":
            return "seven_day"
        case "weekly_scoped":
            let scope = entry["scope"] as? [String: Any]
            if let model = scope?["model"] as? [String: Any],
               let display = model["display_name"] as? String, !display.isEmpty {
                return "seven_day_" + display.lowercased()
            }
            if let surface = scope?["surface"] as? String, !surface.isEmpty {
                return "seven_day_" + surface.lowercased()
            }
            return "seven_day_scoped"
        default:
            return kind
        }
    }

    // Primary path: parses the "limits" array Anthropic now sends. Each entry
    // uses "percent" instead of "utilization". Falls back to the old
    // utilization-scan below when "limits" is missing or empty.
    private func parseLimits(_ limits: [[String: Any]]) -> [UsageBucket] {
        var buckets: [UsageBucket] = []
        for entry in limits {
            guard let pct = (entry["percent"] as? NSNumber)?.doubleValue else { continue }
            let key = limitBucketKey(entry)
            buckets.append(UsageBucket(
                key: key,
                label: prettyBucketLabel(key),
                utilization: max(0, min(100, pct)),
                resetsAt: iso8601Date(entry["resets_at"] as? String),
                severity: entry["severity"] as? String,
                isActive: (entry["is_active"] as? Bool) ?? false))
        }
        return buckets
    }

    // Fallback parser (pre-"limits" API shape): any object in the response
    // that carries a numeric "utilization" becomes a bar. New buckets
    // Anthropic ships show up automatically without an app update.
    private func parseUtilizationScan(_ json: [String: Any]) -> [UsageBucket] {
        var buckets: [UsageBucket] = []
        for (key, value) in json {
            guard let dict = value as? [String: Any] else { continue }
            if key == "extra_usage" { continue }
            guard let util = (dict["utilization"] as? NSNumber)?.doubleValue else { continue }
            buckets.append(UsageBucket(
                key: key,
                label: prettyBucketLabel(key),
                utilization: max(0, min(100, util)),
                resetsAt: iso8601Date(dict["resets_at"] as? String),
                severity: nil,
                isActive: false))
        }
        return buckets
    }

    // Preferred path: the richer top-level "spend" object. Broken into small
    // intermediate lets on purpose, the swiftc type checker on this machine
    // has hung on complex chained optional casts involving NSNumber.
    private func parseSpend(_ json: [String: Any]) -> ExtraUsage? {
        guard let spend = json["spend"] as? [String: Any] else { return nil }
        let enabled = (spend["enabled"] as? Bool) ?? false
        guard enabled else { return nil }
        guard let usedDict = spend["used"] as? [String: Any] else { return nil }
        let usedNumber = usedDict["amount_minor"] as? NSNumber
        let usedCents = usedNumber?.doubleValue ?? 0

        var limitCents: Double = 0
        if let limitDict = spend["limit"] as? [String: Any] {
            let limitNumber = limitDict["amount_minor"] as? NSNumber
            limitCents = limitNumber?.doubleValue ?? 0
        }

        let currency = (usedDict["currency"] as? String) ?? "USD"
        let percentNumber = spend["percent"] as? NSNumber
        let percent = percentNumber?.doubleValue
        let severity = spend["severity"] as? String

        var balanceCents: Double? = nil
        if let balanceDict = spend["balance"] as? [String: Any] {
            let balanceNumber = balanceDict["amount_minor"] as? NSNumber
            balanceCents = balanceNumber?.doubleValue
        }

        return ExtraUsage(
            usedCents: usedCents,
            limitCents: limitCents,
            currency: currency,
            percent: percent,
            severity: severity,
            balanceCents: balanceCents)
    }

    // Fallback path: the older "extra_usage" object. Now also tolerates a
    // null/missing monthly_limit (treated as 0, meaning "no cap") as long as
    // the feature is enabled and a used_credits value is present.
    private func parseExtraUsage(_ json: [String: Any]) -> ExtraUsage? {
        guard let dict = json["extra_usage"] as? [String: Any] else { return nil }
        let enabled = (dict["is_enabled"] as? Bool) ?? false
        guard enabled else { return nil }
        guard let usedNumber = dict["used_credits"] as? NSNumber else { return nil }
        let usedCents = usedNumber.doubleValue
        let limitNumber = dict["monthly_limit"] as? NSNumber
        let limitCents = limitNumber?.doubleValue ?? 0
        let currency = (dict["currency"] as? String) ?? "USD"
        return ExtraUsage(
            usedCents: usedCents,
            limitCents: limitCents,
            currency: currency,
            percent: nil,
            severity: nil,
            balanceCents: nil)
    }

    private func parse(_ json: [String: Any]) -> UsageSnapshot {
        var buckets: [UsageBucket]
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            buckets = parseLimits(limits)
        } else {
            buckets = parseUtilizationScan(json)
        }

        var extra: ExtraUsage? = parseSpend(json)
        if extra == nil {
            extra = parseExtraUsage(json)
        }

        let order = ["five_hour", "seven_day"]
        buckets.sort { a, b in
            let ia = order.firstIndex(of: a.key) ?? Int.max
            let ib = order.firstIndex(of: b.key) ?? Int.max
            if ia != ib { return ia < ib }
            return a.label < b.label
        }
        return UsageSnapshot(buckets: buckets, extra: extra, fetchedAt: Date())
    }
}

// MARK: - Local per-model stats from Claude Code transcripts

final class LocalStats {
    func compute(completion: @escaping ([ModelStat]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.computeSync())
        }
    }

    private func computeSync() -> [ModelStat] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: PROJECTS_DIR) else { return [] }
        let cutoffFile = Date().addingTimeInterval(-8 * 86400)
        let cutoff7d = Date().addingTimeInterval(-7 * 86400)
        let todayStart = Calendar.current.startOfDay(for: Date())
        var stats: [String: ModelStat] = [:]
        var seen = Set<String>()

        for proj in projects {
            let dir = PROJECTS_DIR + "/" + proj
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = dir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime > cutoffFile,
                      let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                for line in content.split(separator: "\n") {
                    guard line.contains("\"assistant\""),
                          let data = line.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          (obj["type"] as? String) == "assistant",
                          let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any],
                          let model = msg["model"] as? String,
                          !model.contains("synthetic"),
                          let ts = iso8601Date(obj["timestamp"] as? String),
                          ts > cutoff7d else { continue }
                    let msgId: String = (msg["id"] as? String) ?? ""
                    var reqId: String = (obj["requestId"] as? String) ?? ""
                    if reqId.isEmpty { reqId = (obj["uuid"] as? String) ?? "" }
                    let dedupe: String = msgId + ":" + reqId
                    if dedupe != ":" {
                        if seen.contains(dedupe) { continue }
                        seen.insert(dedupe)
                    }
                    var tokens = 0
                    for field in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                        if let n = usage[field] as? NSNumber { tokens += n.intValue }
                    }
                    let name = prettyModelName(model)
                    var stat = stats[name] ?? ModelStat(name: name)
                    stat.tokens7d += tokens
                    if ts >= todayStart { stat.tokensToday += tokens }
                    stats[name] = stat
                }
            }
        }
        return stats.values.sorted { $0.tokens7d > $1.tokens7d }
    }
}

// MARK: - Optional API spend (needs an Anthropic Admin API key)

final class APISpend {
    static let account = "admin-api-key"

    static var storedKey: String? {
        guard let item = keychainRead(service: PULSE_KEYCHAIN_SERVICE) else { return nil }
        return String(data: item.data, encoding: .utf8)
    }

    static func store(key: String) {
        keychainWrite(service: PULSE_KEYCHAIN_SERVICE, account: account, data: Data(key.utf8))
    }

    static func removeKey() {
        keychainDelete(service: PULSE_KEYCHAIN_SERVICE, account: account)
    }

    static func fetch7DayTotal(completion: @escaping (String) -> Void) {
        guard let key = storedKey, !key.isEmpty else {
            completion("")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let start = Date().addingTimeInterval(-7 * 86400)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            var comps = URLComponents(string: COST_URL)!
            comps.queryItems = [URLQueryItem(name: "starting_at", value: f.string(from: start))]
            var req = URLRequest(url: comps.url!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.timeoutInterval = 20

            let sem = DispatchSemaphore(value: 0)
            var result: (Data?, URLResponse?, Error?)
            URLSession.shared.dataTask(with: req) { d, r, e in
                result = (d, r, e)
                sem.signal()
            }.resume()
            sem.wait()

            guard result.2 == nil,
                  let http = result.1 as? HTTPURLResponse,
                  let data = result.0 else {
                completion("Spend: network error")
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion("Spend: key rejected (needs an Admin key)")
                return
            }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                completion("Spend: HTTP \(http.statusCode)")
                return
            }
            var total = 0.0
            sumAmounts(json, into: &total)
            completion(String(format: "API spend · last 7 days: $%.2f", total))
        }
    }

    // Walks any JSON shape and sums every "amount" it finds.
    private static func sumAmounts(_ node: Any, into total: inout Double) {
        if let dict = node as? [String: Any] {
            for (k, v) in dict {
                if k == "amount" {
                    if let n = v as? NSNumber { total += n.doubleValue }
                    else if let s = v as? String, let d = Double(s) { total += d }
                } else {
                    sumAmounts(v, into: &total)
                }
            }
        } else if let arr = node as? [Any] {
            for v in arr { sumAmounts(v, into: &total) }
        }
    }
}

// MARK: - Icon rendering

enum IconStyle: String, CaseIterable {
    case ring, bar, percent, orb, flip

    var label: String {
        switch self {
        case .ring: return "Ring + percent"
        case .bar: return "Battery bar"
        case .percent: return "Percent only"
        case .orb: return "Liquid orb"
        case .flip: return "Ring + spark flip"
        }
    }
}

enum IconMetric: String, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case highest = "highest"

    var label: String {
        switch self {
        case .fiveHour: return "5-hour limit"
        case .sevenDay: return "Weekly limit"
        case .highest: return "Highest of all"
        }
    }
}

let claudeCoral = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1.0) // D97757

// An original eight-ray spark, drawn from scratch. Evocative of an AI
// assistant's sparkle without copying anyone's actual trademarked mark.
func renderSpark(stale: Bool) -> NSImage? {
    let tint = stale ? NSColor.systemGray : claudeCoral
    let size = NSSize(width: 18, height: 18)
    return NSImage(size: size, flipped: false) { _ in
        let center = NSPoint(x: 9, y: 9)
        for i in 0..<8 {
            let angle = CGFloat(i) * (.pi / 4.0)
            let isLong = i % 2 == 0
            let inner: CGFloat = 1.6
            let outer: CGFloat = isLong ? 7.4 : 5.2
            let path = NSBezierPath()
            path.move(to: NSPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            path.line(to: NSPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
            path.lineWidth = 2.4
            path.lineCapStyle = .round
            tint.setStroke()
            path.stroke()
        }
        return true
    }
}

func renderIcon(style: IconStyle, pct: Double, pulsePhase: Bool, stale: Bool, sparkPhase: Bool = false) -> NSImage? {
    let color = stale ? NSColor.systemGray : thresholdColor(pct)
    let fracD: Double = max(0.0, min(1.0, pct / 100.0))
    let frac = CGFloat(fracD)

    var style = style
    if style == .flip {
        if sparkPhase { return renderSpark(stale: stale) }
        style = .ring
    }

    switch style {
    case .percent:
        return nil
    case .ring:
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            let radius: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.6
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()
            if frac > 0.005 {
                let arc = NSBezierPath()
                let endAngle: CGFloat = 90.0 - 360.0 * frac
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: endAngle, clockwise: true)
                arc.lineWidth = 2.6
                arc.lineCapStyle = .round
                var c = color
                if pct >= 90 && pulsePhase { c = color.withAlphaComponent(0.45) }
                c.setStroke()
                arc.stroke()
            }
            return true
        }
    case .bar:
        let size = NSSize(width: 24, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 3.5, width: 20, height: 9), xRadius: 2.5, yRadius: 2.5)
            body.lineWidth = 1
            NSColor.secondaryLabelColor.setStroke()
            body.stroke()
            let cap = NSBezierPath(roundedRect: NSRect(x: 21.5, y: 6, width: 2, height: 4), xRadius: 1, yRadius: 1)
            NSColor.secondaryLabelColor.setFill()
            cap.fill()
            let w = max(0, (18.0 * frac))
            if w > 0.5 {
                var c = color
                if pct >= 90 && pulsePhase { c = color.withAlphaComponent(0.45) }
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: w, height: 7), xRadius: 1.8, yRadius: 1.8).fill()
            }
            return true
        }
    case .orb:
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: 1, y: 1, width: 16, height: 16)
            let circle = NSBezierPath(ovalIn: rect)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
            circle.fill()
            NSGraphicsContext.current?.saveGraphicsState()
            circle.addClip()
            let level = rect.minY + rect.height * CGFloat(frac)
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: rect.minX, y: rect.minY))
            fill.line(to: NSPoint(x: rect.minX, y: level))
            // a gentle wave on the surface
            let waveH: CGFloat = frac > 0.02 && frac < 0.98 ? 1.2 : 0
            fill.curve(to: NSPoint(x: rect.midX, y: level + waveH),
                       controlPoint1: NSPoint(x: rect.minX + 3, y: level + waveH),
                       controlPoint2: NSPoint(x: rect.midX - 3, y: level + waveH))
            fill.curve(to: NSPoint(x: rect.maxX, y: level),
                       controlPoint1: NSPoint(x: rect.midX + 3, y: level - waveH),
                       controlPoint2: NSPoint(x: rect.maxX - 3, y: level - waveH))
            fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            fill.close()
            var top = claudeCoral
            var bottom = claudeCoral.blended(withFraction: 0.35, of: .systemRed) ?? claudeCoral
            if stale { top = .systemGray; bottom = .darkGray }
            if pct >= 90 && pulsePhase {
                top = top.withAlphaComponent(0.5)
                bottom = bottom.withAlphaComponent(0.5)
            }
            NSGradient(starting: top, ending: bottom)?.draw(in: fill, angle: -90)
            NSGraphicsContext.current?.restoreGraphicsState()
            let outline = NSBezierPath(ovalIn: rect)
            outline.lineWidth = 1
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
            outline.stroke()
            return true
        }
    case .flip:
        return renderSpark(stale: stale) // unreachable, handled above
    }
}

// MARK: - Menu row views

func barRow(label: String, pct: Double, sub: String?, fillColor: NSColor? = nil) -> NSView {
    let width: CGFloat = 264
    let height: CGFloat = sub == nil ? 36 : 46
    let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

    let title = NSTextField(labelWithString: label)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.frame = NSRect(x: 14, y: height - 20, width: 180, height: 17)
    view.addSubview(title)

    let pctLabel = NSTextField(labelWithString: String(format: "%.0f%%", pct))
    pctLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    pctLabel.alignment = .right
    pctLabel.textColor = .secondaryLabelColor
    pctLabel.frame = NSRect(x: width - 64, y: height - 20, width: 50, height: 17)
    view.addSubview(pctLabel)

    let trackY: CGFloat = sub == nil ? 8 : 18
    let track = NSView(frame: NSRect(x: 14, y: trackY, width: width - 28, height: 5))
    track.wantsLayer = true
    track.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
    track.layer?.cornerRadius = 2.5
    view.addSubview(track)

    let ratio = CGFloat(max(0.0, min(100.0, pct)) / 100.0)
    let fillW: CGFloat = (width - 28.0) * ratio
    if fillW > 1 {
        let fill = NSView(frame: NSRect(x: 14, y: trackY, width: fillW, height: 5))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = (fillColor ?? thresholdColor(pct)).cgColor
        fill.layer?.cornerRadius = 2.5
        view.addSubview(fill)
    }

    if let sub = sub {
        let subLabel = NSTextField(labelWithString: sub)
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.frame = NSRect(x: 14, y: 2, width: width - 28, height: 14)
        view.addSubview(subLabel)
    }
    return view
}

// A menu row backed by a real NSButton instead of an NSMenuItem selection.
// AppKit dismisses the menu automatically whenever an NSMenuItem's action
// fires, that's what made "Refresh Now" close the dropdown on every click.
// A button living inside an NSMenuItem's custom view does not trigger that
// dismissal, so the menu stays open, matching Track API Spend and the other
// action rows in feel while behaving like the always-visible utility item
// it is meant to be. Keeps the same target/action wiring as a normal item,
// so nothing about what runs on click changes, only whether the menu closes.
func menuButtonRow(title: String, keyEquivalent: String, target: AnyObject, action: Selector) -> NSView {
    let width: CGFloat = 264
    let height: CGFloat = 22
    let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

    let button = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: height))
    button.title = title
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .systemFont(ofSize: 13, weight: .regular)
    button.alignment = .left
    button.contentTintColor = .labelColor
    (button.cell as? NSButtonCell)?.imagePosition = .noImage
    button.target = target
    button.action = action
    button.setButtonType(.momentaryChange)
    // NSMenu's key-equivalent tracking checks each visible item's view for a
    // button with a matching keyEquivalent, so ⌘R still fires while the menu
    // is open, same as it did as a plain NSMenuItem keyEquivalent.
    if !keyEquivalent.isEmpty {
        button.keyEquivalent = keyEquivalent
        button.keyEquivalentModifierMask = .command
    }
    view.addSubview(button)

    // Keep the ⌘R hint visible on the right, matching how NSMenuItem shows
    // key equivalents, even though this row is no longer a real menu item.
    if !keyEquivalent.isEmpty {
        let hint = NSTextField(labelWithString: "⌘" + keyEquivalent.uppercased())
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        hint.frame = NSRect(x: width - 40, y: 2, width: 26, height: 16)
        hint.isEditable = false
        hint.isSelectable = false
        view.addSubview(hint)
        button.frame = NSRect(x: 0, y: 0, width: width - 44, height: height)
    }

    // Indent to match NSMenuItem's default title inset.
    button.frame.origin.x = 14
    button.frame.size.width -= 14

    return view
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let fetcher = UsageFetcher()
    let localStats = LocalStats()
    let menu = NSMenu()

    var snapshot: UsageSnapshot?
    var lastError: PulseError?
    var lastSuccessAt: Date?
    var models: [ModelStat] = []
    var spendLine: String = ""
    var pulsePhase = false
    var sparkPhase = false
    var reconnecting = false
    private var lastFetchAt = Date.distantPast
    private var usageRetryAttempt = 0
    private var usageRetryWork: DispatchWorkItem?
    static let positionKey = "NSStatusItem Preferred Position Pulse"

    var iconStyle: IconStyle {
        get { IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyle") ?? "") ?? .ring }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconStyle") }
    }
    var iconMetric: IconMetric {
        get { IconMetric(rawValue: UserDefaults.standard.string(forKey: "iconMetric") ?? "") ?? .fiveHour }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconMetric") }
    }

    // Manual anchor for counting down purchased credits, since the OAuth
    // usage API does not yet expose a live balance. 0 means unset.
    var anchorBalanceCents: Double {
        get { UserDefaults.standard.double(forKey: "CreditsAnchorBalanceCents") }
        set { UserDefaults.standard.set(newValue, forKey: "CreditsAnchorBalanceCents") }
    }
    var anchorUsedCents: Double {
        get { UserDefaults.standard.double(forKey: "CreditsAnchorUsedCents") }
        set { UserDefaults.standard.set(newValue, forKey: "CreditsAnchorUsedCents") }
    }

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Pulse"
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = " …"
        statusItem.menu = menu
    }

    // Accessory apps have no visible menu bar menus, but AppKit still routes
    // Cmd+V/C/X/A through NSApp.mainMenu key equivalents. Without this hidden
    // Edit menu, paste does not work in any NSAlert text field (the Track API
    // Spend and Set Credits Balance dialogs).
    private func installHiddenEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installHiddenEditMenu()
        // First run: ask macOS to place us as far right as third-party
        // items are allowed to go (small value = closer to the clock).
        if UserDefaults.standard.object(forKey: AppController.positionKey) == nil {
            UserDefaults.standard.set(20.0, forKey: AppController.positionKey)
        }
        menu.delegate = self
        makeStatusItem()
        rebuildMenu()

        refreshUsage()
        refreshModels()
        refreshSpend()

        let usageTimer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in self?.refreshUsage() }
        RunLoop.main.add(usageTimer, forMode: .common)
        let modelsTimer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshModels()
            self?.refreshSpend()
        }
        RunLoop.main.add(modelsTimer, forMode: .common)
        let pulseTimer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if (self.metricPct ?? 0) >= 90 {
                self.pulsePhase.toggle()
                self.updateButton()
            } else if self.pulsePhase {
                self.pulsePhase = false
                self.updateButton()
            }
        }
        RunLoop.main.add(pulseTimer, forMode: .common)
        let flipTimer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.iconStyle == .flip else { return }
            self.sparkPhase = true
            self.updateButton()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.sparkPhase = false
                self?.updateButton()
            }
        }
        RunLoop.main.add(flipTimer, forMode: .common)
    }

    var metricPct: Double? {
        guard let snap = snapshot else { return nil }
        switch iconMetric {
        case .fiveHour: return snap.bucket("five_hour")?.utilization ?? snap.maxBucket?.utilization
        case .sevenDay: return snap.bucket("seven_day")?.utilization ?? snap.maxBucket?.utilization
        case .highest: return snap.maxBucket?.utilization
        }
    }

    // MARK: refreshes

    func refreshUsage(force: Bool = false) {
        if !force {
            // TTL cache: if data is fresh enough, skip the fetch entirely.
            if let s = lastSuccessAt, Date().timeIntervalSince(s) < USAGE_CACHE_TTL, snapshot != nil, lastError == nil { return }
            // Hammer guard: prevent sub-5s refetch thrashing.
            if Date().timeIntervalSince(lastFetchAt) < 5 { return }
        }
        lastFetchAt = Date()
        fetcher.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var rateLimited = false
                switch result {
                case .success(let snap):
                    self.snapshot = snap
                    self.lastError = nil
                    self.lastSuccessAt = Date()
                    self.usageRetryAttempt = 0
                    self.usageRetryWork?.cancel()
                    self.usageRetryWork = nil
                case .failure(.rateLimited):
                    // Rate limited: keep showing the last good snapshot, do
                    // not treat this as an error, just wait for next poll.
                    rateLimited = true
                case .failure(let err):
                    self.lastError = err
                    // Retry transient failures only (network, HTTP 5xx).
                    if err.isTransient && self.usageRetryAttempt < RETRY_DELAYS.count {
                        self.usageRetryWork?.cancel()
                        let work = DispatchWorkItem { [weak self] in
                            self?.refreshUsage(force: true)
                        }
                        self.usageRetryWork = work
                        let delay = RETRY_DELAYS[self.usageRetryAttempt]
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                        self.usageRetryAttempt += 1
                    }
                }
                self.updateButton()
                self.rebuildMenu()
                self.writeStatusFile(rateLimited: rateLimited)
            }
        }
    }

    // Best-effort health file for external checks (cat, monitoring scripts).
    // Piggybacks on the existing poll, no extra network calls. Never throws,
    // never crashes the app, a missing or stale file just reads as unhealthy.
    private func writeStatusFile(rateLimited: Bool) {
        let dir = NSString(string: "~/Library/Application Support/Pulse for Claude").expandingTildeInPath
        let path = dir + "/status.json"

        var bucketKeys: [String] = []
        var bucketLabels: [String] = []
        var extraUsedDollars: Double? = nil
        var creditsBalanceDollars: Double? = nil
        if let snap = snapshot {
            bucketKeys = snap.buckets.map { $0.key }
            bucketLabels = snap.buckets.map { $0.label }
            if let extra = snap.extra {
                extraUsedDollars = extra.usedCents / 100
                var balanceCents: Double? = nil
                if let apiBalance = extra.balanceCents {
                    balanceCents = apiBalance
                } else if anchorBalanceCents > 0 {
                    let usedSinceAnchor = extra.usedCents - anchorUsedCents
                    let usedSinceAnchorClamped = max(0, usedSinceAnchor)
                    let remaining = anchorBalanceCents - usedSinceAnchorClamped
                    balanceCents = max(0, remaining)
                }
                if let bc = balanceCents { creditsBalanceDollars = bc / 100 }
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lastSuccessStr: Any = NSNull()
        if let lsa = lastSuccessAt { lastSuccessStr = iso.string(from: lsa) }
        let payload: [String: Any] = [
            "version": APP_VERSION,
            "updatedAt": iso.string(from: Date()),
            "healthy": snapshot != nil && lastError == nil,
            "lastError": jsonValue(lastError?.description),
            "bucketKeys": bucketKeys,
            "bucketLabels": bucketLabels,
            "extraUsedDollars": jsonValue(extraUsedDollars),
            "creditsBalanceDollars": jsonValue(creditsBalanceDollars),
            "rateLimited": rateLimited,
            "lastSuccessAt": lastSuccessStr,
        ]

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func refreshModels() {
        localStats.compute { [weak self] stats in
            DispatchQueue.main.async {
                self?.models = stats
                self?.rebuildMenu()
            }
        }
    }

    func refreshSpend() {
        APISpend.fetch7DayTotal { [weak self] line in
            DispatchQueue.main.async {
                self?.spendLine = line
                self?.rebuildMenu()
            }
        }
    }

    // MARK: status button

    func updateButton() {
        guard let button = statusItem.button else { return }
        let stale = lastError != nil && snapshot == nil
        let pct = metricPct ?? 0

        if snapshot == nil && lastError == nil {
            button.image = renderIcon(style: iconStyle, pct: 0, pulsePhase: false, stale: true)
            button.title = " …"
            return
        }
        if stale {
            button.image = renderIcon(style: iconStyle, pct: 0, pulsePhase: false, stale: true)
            button.attributedTitle = NSAttributedString(string: " !", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.systemOrange,
                .baselineOffset: 0.5,
            ])
            button.toolTip = "\(APP_NAME): \(lastError?.description ?? "error")"
            return
        }

        button.image = renderIcon(style: iconStyle, pct: pct, pulsePhase: pulsePhase, stale: false, sparkPhase: sparkPhase)
        let text = String(format: " %.0f%%", pct)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .baselineOffset: 0.5,
        ]
        if iconStyle == .percent {
            attrs[.foregroundColor] = thresholdColor(pct)
            attrs[.font] = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        }
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)

        if let snap = snapshot {
            var tip = APP_NAME
            for b in snap.buckets.prefix(3) {
                tip += "\n\(b.label): \(Int(b.utilization))%"
                if let r = b.resetsAt { tip += " · resets in \(timeLeftString(until: r))" }
            }
            button.toolTip = tip
        }
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        refreshUsage()
        refreshModels()
        rebuildMenu()
    }

    func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(string: APP_NAME, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
        ])
        header.isEnabled = false
        menu.addItem(header)

        let refreshNow = NSMenuItem()
        refreshNow.view = menuButtonRow(title: "Refresh Now", keyEquivalent: "r", target: self, action: #selector(manualRefresh))
        menu.addItem(refreshNow)
        menu.addItem(.separator())

        if reconnecting {
            menu.addItem(infoItem("Reconnecting to Claude…"))
        } else if let err = lastError, snapshot == nil {
            menu.addItem(infoItem(err.description))
            switch err {
            case .noCredentials:
                menu.addItem(infoItem("Install Claude Code, sign in once, then Reconnect."))
                addReconnectItem()
            case .loginExpired:
                menu.addItem(infoItem("Your Claude login expired. One click fixes it:"))
                addReconnectItem()
            case .network:
                menu.addItem(infoItem("Check your internet connection, then Refresh."))
            case .rateLimited:
                menu.addItem(infoItem("Anthropic is rate limiting requests. Waiting for the next poll."))
            case .httpError:
                menu.addItem(infoItem("Server error. Retrying automatically."))
            }
        }

        if let snap = snapshot {
            for bucket in snap.buckets {
                var sub: String? = nil
                if let r = bucket.resetsAt, r.timeIntervalSinceNow > 0 {
                    sub = "resets in " + timeLeftString(until: r)
                }
                if bucket.isActive {
                    let activeSuffix = "· active"
                    sub = sub == nil ? activeSuffix : sub! + " " + activeSuffix
                }
                let item = NSMenuItem()
                item.view = barRow(label: bucket.label, pct: bucket.utilization, sub: sub)
                menu.addItem(item)
            }
            if let extra = snap.extra {
                let used = String(format: "$%.2f", extra.usedCents / 100)
                var fillColor = claudeCoral
                if extra.severity == "warning" { fillColor = .systemOrange }
                else if extra.severity == "critical" { fillColor = .systemRed }

                let pct: Double
                let sub: String
                if extra.limitCents > 0 {
                    pct = extra.percent ?? ((extra.usedCents / extra.limitCents) * 100)
                    let limit = String(format: "$%.2f", extra.limitCents / 100)
                    sub = "\(used) of \(limit) extra usage"
                } else {
                    pct = 0
                    let resetLabel = nextMonthResetLabel()
                    sub = "\(used) used this month · no cap · resets \(resetLabel)"
                }
                let item = NSMenuItem()
                item.view = barRow(label: "Usage credits", pct: pct, sub: sub, fillColor: fillColor)
                menu.addItem(item)

                // Credits balance row: prefer the API-provided balance once
                // Anthropic wires it up. Until then, fall back to counting
                // down from the manual anchor the user set once.
                var balanceCents: Double? = nil
                var anchorTotal: Double = 0
                if let apiBalance = extra.balanceCents {
                    balanceCents = apiBalance
                } else if anchorBalanceCents > 0 {
                    let usedSinceAnchor = extra.usedCents - anchorUsedCents
                    let usedSinceAnchorClamped = max(0, usedSinceAnchor)
                    let remaining = anchorBalanceCents - usedSinceAnchorClamped
                    let remainingClamped = max(0, remaining)
                    balanceCents = remainingClamped
                    anchorTotal = anchorBalanceCents
                }

                if let balance = balanceCents {
                    let balancePct: Double
                    if anchorTotal > 0 {
                        let ratio = balance / anchorTotal
                        let rawPct = ratio * 100
                        balancePct = max(0, min(100, rawPct))
                    } else {
                        balancePct = 100
                    }

                    let balanceStr = String(format: "$%.2f", balance / 100)
                    let balanceSub: String
                    if anchorTotal > 0 {
                        let totalStr = String(format: "$%.2f", anchorTotal / 100)
                        balanceSub = "\(balanceStr) left of \(totalStr)"
                    } else {
                        balanceSub = "\(balanceStr) left"
                    }

                    var balanceColor = NSColor.systemGreen
                    if balancePct > 30 {
                        balanceColor = .systemGreen
                    } else if balancePct > 10 {
                        balanceColor = .systemOrange
                    } else {
                        balanceColor = .systemRed
                    }

                    let balanceItem = NSMenuItem()
                    balanceItem.view = barRow(label: "Credits balance", pct: balancePct, sub: balanceSub, fillColor: balanceColor)
                    menu.addItem(balanceItem)
                }
            }
            if let stalenessErr = lastError, !reconnecting {
                var msg = "Last update failed: \(stalenessErr.description)"
                if let lsa = lastSuccessAt {
                    msg += " · data \(relativeAgeString(lsa))"
                }
                menu.addItem(infoItem(msg))
                if case .loginExpired = stalenessErr { addReconnectItem() }
            } else if reconnecting {
                menu.addItem(infoItem("Reconnecting to Claude…"))
            }
        }

        if !models.isEmpty {
            menu.addItem(.separator())
            let mh = NSMenuItem()
            mh.attributedTitle = NSAttributedString(string: "Models · last 7 days (local)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            mh.isEnabled = false
            menu.addItem(mh)
            for m in models.prefix(6) {
                let line = String(format: "%@   %@ · today %@", m.name, compactTokens(m.tokens7d), compactTokens(m.tokensToday))
                let item = NSMenuItem()
                item.attributedTitle = NSAttributedString(string: line, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                ])
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        // API spend section
        menu.addItem(.separator())
        if APISpend.storedKey != nil {
            menu.addItem(infoItem(spendLine.isEmpty ? "API spend: loading…" : spendLine))
            let remove = NSMenuItem(title: "Remove API Spend Key", action: #selector(removeSpendKey), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        } else {
            let add = NSMenuItem(title: "Track API Spend (optional)…", action: #selector(addSpendKey), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
        }

        let setBalance = NSMenuItem(title: "Set Credits Balance…", action: #selector(setCreditsBalance), keyEquivalent: "")
        setBalance.target = self
        menu.addItem(setBalance)

        // settings
        menu.addItem(.separator())
        let styleMenu = NSMenu()
        for style in IconStyle.allCases {
            let item = NSMenuItem(title: style.label, action: #selector(pickStyle(_:)), keyEquivalent: "")
            item.representedObject = style.rawValue
            item.state = style == iconStyle ? .on : .off
            item.target = self
            styleMenu.addItem(item)
        }
        let styleRoot = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: "")
        menu.setSubmenu(styleMenu, for: styleRoot)
        menu.addItem(styleRoot)

        let metricMenu = NSMenu()
        for metric in IconMetric.allCases {
            let item = NSMenuItem(title: metric.label, action: #selector(pickMetric(_:)), keyEquivalent: "")
            item.representedObject = metric.rawValue
            item.state = metric == iconMetric ? .on : .off
            item.target = self
            metricMenu.addItem(item)
        }
        let metricRoot = NSMenuItem(title: "Icon Shows", action: nil, keyEquivalent: "")
        menu.setSubmenu(metricMenu, for: metricRoot)
        menu.addItem(metricRoot)

        let pin = NSMenuItem(title: "Pin to Far Right", action: #selector(pinFarRight), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            login.target = self
            menu.addItem(login)
        }

        let reconnectItem = NSMenuItem(title: "Reconnect to Claude", action: #selector(reconnectAction), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.isEnabled = !reconnecting
        menu.addItem(reconnectItem)

        let openUsage = NSMenuItem(title: "Open Usage Settings on claude.ai", action: #selector(openClaudeUsage), keyEquivalent: "")
        openUsage.target = self
        menu.addItem(openUsage)

        menu.addItem(.separator())
        if let snap = snapshot {
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            var footer = "Updated \(df.string(from: snap.fetchedAt)) · refreshes every 2 minutes"
            // Add staleness indicator if data is older than 10 minutes (missed polls).
            if let lsa = lastSuccessAt, lastError == nil, Date().timeIntervalSince(lsa) >= 600 {
                footer += " · data \(relativeAgeString(lsa))"
            }
            menu.addItem(infoItem(footer))
        }
        let about = NSMenuItem(title: "About \(APP_NAME)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func infoItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    // MARK: actions

    @objc func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = IconStyle(rawValue: raw) {
            iconStyle = style
            updateButton()
        }
    }

    @objc func pickMetric(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let metric = IconMetric(rawValue: raw) {
            iconMetric = metric
            updateButton()
        }
    }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not change Launch at Login"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc func manualRefresh() {
        // If the login is dead, retrying it does nothing. The useful action is
        // to reconnect, so Refresh Now does exactly that in that situation.
        let loginDead: Bool = {
            if case .loginExpired? = lastError { return true }
            if case .noCredentials? = lastError { return true }
            return false
        }()
        if loginDead {
            reconnectAction()
            return
        }
        // Cancel any pending retry work and reset the retry counter.
        usageRetryWork?.cancel()
        usageRetryWork = nil
        usageRetryAttempt = 0
        refreshUsage(force: true)
        refreshModels()
        refreshSpend()
    }

    // Adds a bold, obvious Reconnect button into the menu's error area.
    func addReconnectItem() {
        let item = NSMenuItem(title: reconnecting ? "Reconnecting…" : "Reconnect to Claude", action: #selector(reconnectAction), keyEquivalent: "")
        item.target = self
        item.isEnabled = !reconnecting
        item.attributedTitle = NSAttributedString(string: reconnecting ? "Reconnecting…" : "Reconnect to Claude", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: reconnecting ? NSColor.secondaryLabelColor : claudeCoral,
        ])
        menu.addItem(item)
    }

    // Runs Claude Code's official sign-in to revive the login, then refreshes.
    // Opens the browser, which completes on its own if signed in to claude.com.
    @objc func reconnectAction() {
        if reconnecting { return }
        reconnecting = true
        rebuildMenu()
        updateButton()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = self?.fetcher.credentials.reconnectViaClaudeCLI() ?? false
            DispatchQueue.main.async {
                self?.reconnecting = false
                if ok { self?.lastError = nil }
                self?.refreshUsage(force: true)
                self?.refreshModels()
                self?.refreshSpend()
                if !ok {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Could not reconnect automatically"
                    alert.informativeText = "Open Claude Code (or the Claude desktop app's Code tab), sign in once, then click Reconnect again."
                    alert.runModal()
                }
            }
        }
    }

    // Re-creates the status item with a position hint that puts it as far
    // right as macOS lets third-party items go (the system cluster with
    // Control Center and the clock cannot be passed). Cmd-drag also works.
    @objc func pinFarRight() {
        NSStatusBar.system.removeStatusItem(statusItem)
        UserDefaults.standard.set(20.0, forKey: AppController.positionKey)
        makeStatusItem()
        updateButton()
    }

    @objc func openClaudeUsage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func addSpendKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Track API Spend"
        alert.informativeText = "Optional, for developers who also use the Anthropic API. Paste an Admin API key (starts with sk-ant-admin). It is stored only in your Mac's Keychain. Regular API keys cannot read spend."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "sk-ant-admin…"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                APISpend.store(key: key)
                refreshSpend()
            }
        }
    }

    @objc func removeSpendKey() {
        APISpend.removeKey()
        spendLine = ""
        rebuildMenu()
    }

    // Manual anchor entry point. Pulse cannot read a live balance from the
    // API yet (spend.balance is null as of this writing), so the user gives
    // us a starting point once and we count it down from spend deltas.
    @objc func setCreditsBalance() {
        guard let snap = snapshot, let extra = snap.extra else {
            NSApp.activate(ignoringOtherApps: true)
            let waitAlert = NSAlert()
            waitAlert.messageText = "Not ready yet"
            waitAlert.informativeText = "Usage data has not loaded yet. Wait for the next refresh and try again."
            waitAlert.runModal()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set Credits Balance"
        alert.informativeText = "Enter your current balance from claude.ai (Settings, Usage). Pulse will count it down as you spend."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "74.29"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: "$", with: "")
            text = text.replacingOccurrences(of: " ", with: "")
            guard let dollars = Double(text) else { return }
            anchorBalanceCents = dollars * 100
            anchorUsedCents = extra.usedCents
            rebuildMenu()
        }
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(APP_NAME) \(APP_VERSION)"
        alert.informativeText = "A live meter for your Claude plan usage, right in the menu bar.\n\nReads the same numbers the Claude app shows in Settings. Your login never leaves your Mac.\n\nBuilt with Claude by Ant the AI Guy · Everyday AI Club"
        alert.addButton(withTitle: "Nice")
        alert.runModal()
    }
}

// MARK: - main

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
