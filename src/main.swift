// Pulse for Claude
// A tiny menu bar meter for your Claude plan usage.
// Built with Claude by Ant the AI Guy (Everyday AI Club).
// License: MIT

import AppKit
import Security
import ServiceManagement

let APP_NAME = "Pulse for Claude"
let APP_VERSION = "1.0.2"
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
}

struct ExtraUsage {
    let usedCents: Double
    let limitCents: Double
    let currency: String
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

    var description: String {
        switch self {
        case .noCredentials: return "No Claude login found"
        case .loginExpired: return "Claude login expired"
        case .network(let m): return m
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
        let own = readOAuth(service: PULSE_CRED_SERVICE)
        ownItemAccess = own?.at ?? ""
        adopt(own, orNewer: false)
        if allowSeed && (accessToken.isEmpty || isExpiredLocked) {
            adopt(readOAuth(service: CC_KEYCHAIN_SERVICE), orNewer: true)
            adopt(readFileOAuth(), orNewer: true)
        }
        loadedOnce = true
    }

    // Copies the live token into our own item if it is not already there. This
    // is what makes the very first run seed the owned item immediately, so the
    // Claude Code dialog is never seen again even if no refresh has happened.
    private func persistOwnLocked() {
        if !accessToken.isEmpty && ownItemAccess != accessToken { writeBackLocked() }
    }

    // The one entry point. Returns a currently-valid access token, refreshing
    // at most once. Serialized so concurrent callers can never double-refresh.
    func validAccessToken() -> Result<String, PulseError> {
        return queue.sync {
            if !loadedOnce || accessToken.isEmpty { loadLocked(allowSeed: true) }
            if accessToken.isEmpty { return .failure(.noCredentials) }
            if !isExpiredLocked { persistOwnLocked(); return .success(accessToken) }
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
            loadLocked(allowSeed: true)
            if !accessToken.isEmpty && !isExpiredLocked { return .success(accessToken) }
            if refreshToken.isEmpty { return .failure(.noCredentials) }
        }

        var lastError = PulseError.loginExpired
        for attempt in 0..<2 {
            if attempt > 0 {
                // Our refresh token was rejected (already spent, or Claude Code
                // rotated it). Re-seed from Claude Code's item and retry once.
                loadLocked(allowSeed: true)
                if !accessToken.isEmpty && !isExpiredLocked { return .success(accessToken) }
            }
            switch postRefresh(refreshToken) {
            case .success(let t):
                accessToken = t.access
                refreshToken = t.refresh
                expiresAt = t.exp
                writeBackLocked()
                return .success(accessToken)
            case .failure(let e):
                lastError = e
            }
        }
        return .failure(lastError)
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

    // Saves the current token to Pulse's OWN keychain item (always free, never
    // prompts) and best-effort to the file. It deliberately does NOT write
    // Claude Code's item, because writing a borrowed item is exactly what
    // triggered the repeating permission dialog. MUST be called on `queue`.
    private func writeBackLocked() {
        let payload: [String: Any] = ["claudeAiOauth": [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": expiresAt,
        ]]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            if keychainWrite(service: PULSE_CRED_SERVICE, account: NSUserName(), data: data) {
                ownItemAccess = accessToken
            }
        }
        // Best-effort file sync so the value is also visible to tooling that
        // reads ~/.claude/.credentials.json. Failure here is harmless.
        if let data0 = FileManager.default.contents(atPath: CRED_FILE),
           var json = (try? JSONSerialization.jsonObject(with: data0)) as? [String: Any] {
            var oauth = (json["claudeAiOauth"] as? [String: Any]) ?? [:]
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = expiresAt
            json["claudeAiOauth"] = oauth
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                let url = URL(fileURLWithPath: CRED_FILE)
                if (try? data.write(to: url, options: .atomic)) == nil {
                    try? data.write(to: url)
                }
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CRED_FILE)
            }
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
        guard http.statusCode == 200 else { return .failure(.network("HTTP \(http.statusCode)")) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.network("Bad usage response"))
        }
        return .success(parse(json))
    }

    // Dynamic parser: any object in the response that carries a numeric
    // "utilization" becomes a bar. New buckets Anthropic ships show up
    // automatically without an app update.
    private func parse(_ json: [String: Any]) -> UsageSnapshot {
        var buckets: [UsageBucket] = []
        var extra: ExtraUsage?
        for (key, value) in json {
            guard let dict = value as? [String: Any] else { continue }
            if key == "extra_usage" {
                let enabled = (dict["is_enabled"] as? Bool) ?? false
                let limit = (dict["monthly_limit"] as? NSNumber)?.doubleValue ?? 0
                if enabled && limit > 0 {
                    extra = ExtraUsage(
                        usedCents: (dict["used_credits"] as? NSNumber)?.doubleValue ?? 0,
                        limitCents: limit,
                        currency: (dict["currency"] as? String) ?? "USD")
                }
                continue
            }
            guard let util = (dict["utilization"] as? NSNumber)?.doubleValue else { continue }
            buckets.append(UsageBucket(
                key: key,
                label: prettyBucketLabel(key),
                utilization: max(0, min(100, util)),
                resetsAt: iso8601Date(dict["resets_at"] as? String)))
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

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let fetcher = UsageFetcher()
    let localStats = LocalStats()
    let menu = NSMenu()

    var snapshot: UsageSnapshot?
    var lastError: PulseError?
    var models: [ModelStat] = []
    var spendLine: String = ""
    var pulsePhase = false
    var sparkPhase = false
    static let positionKey = "NSStatusItem Preferred Position Pulse"

    var iconStyle: IconStyle {
        get { IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyle") ?? "") ?? .ring }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconStyle") }
    }
    var iconMetric: IconMetric {
        get { IconMetric(rawValue: UserDefaults.standard.string(forKey: "iconMetric") ?? "") ?? .fiveHour }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "iconMetric") }
    }

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Pulse"
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = " …"
        statusItem.menu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

        let usageTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshUsage() }
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

    func refreshUsage() {
        fetcher.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let snap):
                    self.snapshot = snap
                    self.lastError = nil
                case .failure(let err):
                    self.lastError = err
                }
                self.updateButton()
                self.rebuildMenu()
            }
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

        if let err = lastError, snapshot == nil {
            menu.addItem(infoItem(err.description))
            switch err {
            case .noCredentials:
                menu.addItem(infoItem("Install Claude Code, run it once, and log in."))
            case .loginExpired:
                menu.addItem(infoItem("Open Claude Code once, then hit Refresh."))
            case .network:
                menu.addItem(infoItem("Check your internet connection, then Refresh."))
            }
        }

        if let snap = snapshot {
            for bucket in snap.buckets {
                var sub: String? = nil
                if let r = bucket.resetsAt, r.timeIntervalSinceNow > 0 {
                    sub = "resets in " + timeLeftString(until: r)
                }
                let item = NSMenuItem()
                item.view = barRow(label: bucket.label, pct: bucket.utilization, sub: sub)
                menu.addItem(item)
            }
            if let extra = snap.extra {
                let pct = extra.limitCents > 0 ? (extra.usedCents / extra.limitCents) * 100 : 0
                let used = String(format: "$%.2f", extra.usedCents / 100)
                let limit = String(format: "$%.2f", extra.limitCents / 100)
                let item = NSMenuItem()
                item.view = barRow(label: "Usage credits", pct: pct, sub: "\(used) of \(limit) extra usage", fillColor: claudeCoral)
                menu.addItem(item)
            }
            if let stalenessErr = lastError {
                menu.addItem(infoItem("Last update failed: \(stalenessErr.description)"))
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

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(manualRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let openUsage = NSMenuItem(title: "Open Usage Settings on claude.ai", action: #selector(openClaudeUsage), keyEquivalent: "")
        openUsage.target = self
        menu.addItem(openUsage)

        menu.addItem(.separator())
        if let snap = snapshot {
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            menu.addItem(infoItem("Updated \(df.string(from: snap.fetchedAt)) · refreshes every minute"))
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
        refreshUsage()
        refreshModels()
        refreshSpend()
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
