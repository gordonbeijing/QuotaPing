// QuotaPing.swift
// macOS 菜单栏工具：google.com 连通检测 + ChatGPT 额度（5 小时 / 每周）
// 单文件实现。构建：bash build.sh
// 调试：QUOTAPING_DEBUG=1 运行时向统一日志输出状态

import AppKit
import SwiftUI
import Combine
import Security
import CoreGraphics
import Sparkle

// MARK: - 全局

let debugMode = ProcessInfo.processInfo.environment["QUOTAPING_DEBUG"] != nil
    || ProcessInfo.processInfo.environment["GOOGLEPING_DEBUG"] != nil

struct AppLogger {
    static let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("QuotaPing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("QuotaPing.log")
    }()
    
    static func log(_ message: String) {
        if debugMode { NSLog("QuotaPing: %@", message) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

/// 重置时间文案：<24h 显示倒计时，否则显示日期（中文）
func resetLabel(_ date: Date) -> String {
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "即将重置" }
    if secs < 24 * 3600 {
        let h = Int(secs) / 3600
        let m = Int(secs) % 3600 / 60
        return h > 0 ? "\(h)h\(m)m 后重置" : "\(m)m 后重置"
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "EEE HH:mm"
    return f.string(from: date)
}

// MARK: - 偏好设置（UserDefaults）

enum Prefs {
    private static let d = UserDefaults.standard

    static func migrateLegacyDefaultsIfNeeded() {
        guard d.bool(forKey: "didMigrateGooglePingDefaults") == false else { return }
        if let legacy = d.persistentDomain(forName: "com.local.googleping") {
            for key in ["pingInterval", "quotaInterval"]
            where d.object(forKey: key) == nil {
                d.set(legacy[key], forKey: key)
            }
        }
        d.set(true, forKey: "didMigrateGooglePingDefaults")
    }

    static var hasShownHelp: Bool {
        get { d.bool(forKey: "hasShownHelp") }
        set { d.set(newValue, forKey: "hasShownHelp") }
    }

    static var pingInterval: Double {
        get { d.object(forKey: "pingInterval") as? Double ?? 30 }
        set { d.set(newValue, forKey: "pingInterval") }
    }

    static var quotaInterval: Double {
        get { max(d.object(forKey: "quotaInterval") as? Double ?? 60, 30) }
        set { d.set(newValue, forKey: "quotaInterval") }
    }

}

// MARK: - 连通检测引擎

enum NetStatus: Equatable {
    case idle
    case checking
    case ok(rtt: Double)      // RTT < 500ms：正常
    case slow(rtt: Double)    // RTT ≥ 500ms：不稳定（半连通，浏览器多半打不开）
    case fail(reason: String)

    var isUp: Bool {
        switch self {
        case .ok: return true
        default: return false
        }
    }

    var debugDescription: String {
        switch self {
        case .idle: return "idle"
        case .checking: return "checking"
        case .ok(let rtt): return "ok(\(Int(rtt.rounded()))ms)"
        case .slow(let rtt): return "slow(\(Int(rtt.rounded()))ms)"
        case .fail(let r): return "fail(\(r))"
        }
    }
}

struct NetworkFailureLog: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let reason: String
    let elapsedMilliseconds: Int
    let url: String

    init(
        id: UUID = UUID(),
        timestamp: Date,
        reason: String,
        elapsedMilliseconds: Int,
        url: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.reason = reason
        self.elapsedMilliseconds = elapsedMilliseconds
        self.url = url
    }
}

enum NetworkIndicatorState {
    case unknown
    case reachable
    case slow
    case timedOut
}

final class ReachabilityEngine: ObservableObject {
    @Published private(set) var status: NetStatus = .idle {
        didSet {
            if status != oldValue {
                switch status {
                case .fail(let reason): AppLogger.log("连通检测失败：\(reason)")
                case .slow(let rtt): AppLogger.log("连通检测缓慢：\(Int(rtt))ms")
                case .ok(let rtt):
                    if case .fail = oldValue { AppLogger.log("网络恢复：\(Int(rtt))ms") }
                    else if case .slow = oldValue { AppLogger.log("网络恢复：\(Int(rtt))ms") }
                default: break
                }
            }
        }
    }
    @Published private(set) var lastChecked: Date?
    @Published private(set) var failureLogs: [NetworkFailureLog] = ReachabilityEngine.loadFailureLogs()

    private var timer: Timer?
    private var inFlight: URLSessionDataTask?
    private let probeURL = URL(string: "https://www.google.com/generate_204")!

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    func start(interval: Double) {
        timer?.invalidate()
        check()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() {
        inFlight?.cancel()
        status = .checking
        var comps = URLComponents(url: probeURL, resolvingAgainstBaseURL: false)!
        // 每次使用不同 URL，避免 URLSession、代理或网关复用旧的 204 响应。
        comps.queryItems = [URLQueryItem(name: "gp", value: UUID().uuidString)]
        var req = URLRequest(url: comps.url!,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 5)
        // generate_204 的标准语义是 GET；HEAD 更容易被中间代理直接代答。
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        req.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let t0 = Date()
        inFlight = session.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = nil
                // 被新一轮探测取代的取消回调，不覆盖当前状态
                if let e = err as? URLError, e.code == .cancelled { return }
                self.lastChecked = Date()
                let elapsed = Date().timeIntervalSince(t0) * 1000
                if let http = resp as? HTTPURLResponse,
                   http.statusCode == 204,
                   http.url?.host?.lowercased() == "www.google.com" {
                    // 慢速成功（如 SYN 重传挤过去的半连通）不算真正可用
                    self.status = elapsed < 500 ? .ok(rtt: elapsed) : .slow(rtt: elapsed)
                    if elapsed >= 500 {
                        self.logUnavailable(reason: "响应过慢", elapsed: elapsed, response: resp)
                    }
                } else if let e = err as? URLError {
                    let reason = Self.reason(for: e.code)
                    self.status = .fail(reason: reason)
                    self.logUnavailable(
                        reason: "\(reason) (URLError \(e.code.rawValue))",
                        elapsed: elapsed,
                        response: resp
                    )
                } else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    let reason = code > 0 ? "HTTP \(code)" : "网络错误"
                    self.status = .fail(reason: reason)
                    self.logUnavailable(reason: reason, elapsed: elapsed, response: resp)
                }
                if debugMode { NSLog("QuotaPing net: \(self.status.debugDescription)") }
            }
        }
        inFlight?.resume()
    }

    private func logUnavailable(reason: String, elapsed: Double, response: URLResponse?) {
        let finalURL = response?.url?.absoluteString ?? probeURL.absoluteString
        let elapsedMilliseconds = Int(elapsed.rounded())
        failureLogs.insert(
            NetworkFailureLog(
                timestamp: Date(),
                reason: reason,
                elapsedMilliseconds: elapsedMilliseconds,
                url: finalURL
            ),
            at: 0
        )
        if failureLogs.count > 1000 {
            failureLogs.removeLast(failureLogs.count - 1000)
        }
        persistFailureLogs()
        NSLog("QuotaPing google.com 不可用：\(reason)，\(elapsedMilliseconds)ms，\(finalURL)")
    }

    func clearFailureLogs() {
        failureLogs.removeAll()
        persistFailureLogs()
    }

    private static var failureLogURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("QuotaPing", isDirectory: true)
            .appendingPathComponent("network-failure-logs.json")
    }

    private static var legacyFailureLogURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("GooglePing", isDirectory: true)
            .appendingPathComponent("network-failure-logs.json")
    }

    private static func loadFailureLogs() -> [NetworkFailureLog] {
        let sourceURL = FileManager.default.fileExists(atPath: failureLogURL.path)
            ? failureLogURL : legacyFailureLogURL
        guard let data = try? Data(contentsOf: sourceURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let logs = try? decoder.decode([NetworkFailureLog].self, from: data) else {
            NSLog("QuotaPing 应用内日志读取失败，将从空记录继续")
            return []
        }
        return Array(logs.prefix(1000))
    }

    private func persistFailureLogs() {
        let url = Self.failureLogURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(failureLogs)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            NSLog("QuotaPing 应用内日志写入失败：\(error.localizedDescription)")
        }
    }

    private static func reason(for code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "超时"
        case .dnsLookupFailed: return "DNS 失败"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "无法连接"
        case .cancelled: return "已取消"
        default: return "网络错误"
        }
    }
}

// MARK: - ChatGPT 额度引擎

struct QuotaWindow: Equatable {
    let usedPercent: Int
    let resetAt: Date
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

enum QuotaStatus: Equatable {
    case idle
    case loading
    case ok(plan: String, fiveHour: QuotaWindow?, weekly: QuotaWindow?, credits: Double?)
    case unavailable(reason: String)

    var debugDescription: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .ok(let plan, let five, let week, let credits):
            let f = five.map { "\($0.remainingPercent)%" } ?? "nil"
            let w = week.map { "\($0.remainingPercent)%" } ?? "nil"
            let c = credits.map { "\($0)" } ?? "nil"
            return "ok(plan=\(plan), 5h=\(f), week=\(w), credits=\(c))"
        case .unavailable(let r): return "unavailable(\(r))"
        }
    }
}

/// Codex CLI 凭据（保留原始 JSON 以便刷新后原样写回，不丢其他字段）
struct CodexAuth {
    var accessToken: String
    var refreshToken: String?
    var accountId: String?
    var rawJSON: [String: Any]
    var fileURL: URL?
}

final class QuotaEngine: ObservableObject {
    @Published private(set) var status: QuotaStatus = .idle

    private var timer: Timer?
    private var auth: CodexAuth?
    private var inFlight = false
    private var hasLoaded = false

    /// 由 AppDelegate 注入：连通探测失败时跳过本轮额度请求
    var isOnline: () -> Bool = { true }

    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"

    func start(interval: Double) {
        timer?.invalidate()
        loadCredentials()
        fetch()
        let t = Timer.scheduledTimer(withTimeInterval: max(interval, 30), repeats: true) { [weak self] _ in
            self?.fetch()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: 凭据

    private func candidateURLs() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        if let ch = ProcessInfo.processInfo.environment["CODEX_HOME"], !ch.isEmpty {
            urls.append(URL(fileURLWithPath: ch, isDirectory: true)
                .appendingPathComponent("auth.json"))
        }
        let home = fm.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent(".codex/auth.json"))
        urls.append(home.appendingPathComponent(".config/codex/auth.json"))
        return urls
    }

    private func loadCredentials() {
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let a = parseAuthData(data, fileURL: url) { auth = a; return }
        }
        if let keyData = keychainLookup(),
           let a = parseAuthData(keyData, fileURL: nil) {
            auth = a
            return
        }
        auth = nil
        if !hasLoaded {
            AppLogger.log("额度刷新失败：未找到 Codex 登录凭据（需 codex login）")
            status = .unavailable(reason: "未找到 Codex 登录凭据（需 codex login）")
        }
    }

    private func parseAuthData(_ data: Data, fileURL: URL?) -> CodexAuth? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let at = tokens["access_token"] as? String else { return nil }
        return CodexAuth(accessToken: at,
                         refreshToken: tokens["refresh_token"] as? String,
                         accountId: tokens["account_id"] as? String,
                         rawJSON: obj, fileURL: fileURL)
    }

    private func keychainLookup() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Codex Auth",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// 刷新后原子写回 auth.json（保留其余字段，权限 0600）
    private func writeBackAuth() {
        guard let auth, let fileURL = auth.fileURL,
              let data = try? JSONSerialization.data(
                  withJSONObject: auth.rawJSON,
                  options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".auth.json.gp.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
            if debugMode { NSLog("QuotaPing auth: 刷新后的 token 已写回 \(fileURL.lastPathComponent)") }
        } catch {
            if debugMode { NSLog("QuotaPing auth: 写回失败 \(error)") }
        }
    }

    // MARK: 查询

    func fetchNow() { fetch() }

    private func fetch() {
        guard !inFlight else { return }
        guard isOnline() else { return }
        if auth == nil { loadCredentials() }   // 允许运行期间 codex login 后自愈
        guard let a = auth else {
            if !hasLoaded {
                status = .unavailable(reason: "未找到 Codex 登录凭据（需 codex login）")
            }
            return
        }
        // access_token 是短期 JWT：距上次刷新超 8 天先主动刷新
        if let lr = lastRefresh(of: a), Date().timeIntervalSince(lr) > 8 * 24 * 3600 {
            refreshTokens { [weak self] ok, expired in
                guard let self else { return }
                if ok { self.writeBackAuth(); self.doFetch() }
                else if expired {
                    self.status = .unavailable(reason: "登录已过期，请重新运行 codex login")
                }
            }
            return
        }
        doFetch()
    }

    private func lastRefresh(of a: CodexAuth) -> Date? {
        // codex CLI 实际格式里 last_refresh 在 JSON 顶层，兼容 tokens 内
        if let s = a.rawJSON["last_refresh"] as? String, let d = Self.parseISO(s) { return d }
        if let s = (a.rawJSON["tokens"] as? [String: Any])?["last_refresh"] as? String,
           let d = Self.parseISO(s) { return d }
        return nil
    }

    private static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s)
    }

    private func doFetch() {
        guard let a = auth else { return }
        if !hasLoaded { status = .loading }
        inFlight = true
        var req = URLRequest(url: usageURL)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(a.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let aid = a.accountId {
            req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if let err = err {
                    AppLogger.log("接口请求网络错误: \(err.localizedDescription)")
                    if !self.hasLoaded { self.status = .unavailable(reason: "网络错误") }
                    if debugMode { NSLog("QuotaPing quota: 请求失败 \(err.localizedDescription)") }
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                switch code {
                case 200:
                    if let data { self.handle(data) }
                    else {
                        AppLogger.log("接口响应空数据")
                        if !self.hasLoaded { self.status = .unavailable(reason: "空响应") }
                    }
                case 401, 403:
                    AppLogger.log("接口 HTTP \(code)，尝试刷新凭证...")
                    if debugMode { NSLog("QuotaPing quota: HTTP \(code), calling refreshTokens") }
                    self.refreshTokens { [weak self] ok, expired in
                        guard let self else { return }
                        if ok {
                            self.writeBackAuth()
                            self.doFetch()      // 重试一次
                        } else if expired {
                            self.status = .unavailable(reason: "登录已过期，请重新运行 codex login")
                        }
                    }
                default:
                    if !self.hasLoaded {
                        self.status = .unavailable(reason: "服务异常（HTTP \(code)）")
                    }
                    if debugMode { NSLog("QuotaPing quota: HTTP \(code)") }
                }
            }
        }.resume()
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = obj["rate_limit"] as? [String: Any] else {
            if !hasLoaded { status = .unavailable(reason: "接口结构已变更") }
            if debugMode { NSLog("QuotaPing quota: 解析失败（缺少 rate_limit）") }
            return
        }
        let plan = (obj["plan_type"] as? String) ?? "unknown"
        func win(_ key: String) -> QuotaWindow? {
            guard let w = rate[key] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.intValue,
                  let reset = (w["reset_at"] as? NSNumber)?.doubleValue else { return nil }
            return QuotaWindow(usedPercent: used, resetAt: Date(timeIntervalSince1970: reset))
        }
        var credits: Double?
        if let c = obj["credits"] as? [String: Any], (c["has_credits"] as? Bool) == true {
            credits = (c["balance"] as? NSNumber)?.doubleValue
        }
        status = .ok(plan: plan,
                     fiveHour: win("primary_window"),
                     weekly: win("secondary_window"),
                     credits: credits)
        hasLoaded = true
        if debugMode { NSLog("QuotaPing quota: \(status.debugDescription)") }
    }

    // MARK: token 刷新（auth.openai.com）

    private func refreshTokens(_ done: @escaping (_ ok: Bool, _ expired: Bool) -> Void) {
        guard let a = auth,
              let s = a.rawJSON["tokens"] as? [String: Any],
              let rt = s["refresh_token"] as? String else {
            AppLogger.log("凭证刷新失败：无 refresh_token")
            if debugMode { NSLog("QuotaPing quota: 无 refresh_token，无法刷新") }
            done(false, true)
            return
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": rt
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                var ok = false
                var expired = false
                if err == nil, let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let at = obj["access_token"] as? String {
                    var tokens = s
                    tokens["access_token"] = at
                    if let nr = obj["refresh_token"] as? String { tokens["refresh_token"] = nr }
                    if let idt = obj["id_token"] as? String { tokens["id_token"] = idt }
                    let iso = ISO8601DateFormatter()
                    tokens["last_refresh"] = iso.string(from: Date())
                    var newAuth = a
                    newAuth.rawJSON["tokens"] = tokens
                    newAuth.rawJSON["last_refresh"] = tokens["last_refresh"] as? String
                    newAuth.accessToken = at
                    newAuth.refreshToken = tokens["refresh_token"] as? String
                    self?.auth = newAuth
                    ok = true
                    AppLogger.log("凭证刷新成功")
                    if debugMode { NSLog("QuotaPing quota: token 刷新成功") }
                } else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    AppLogger.log("凭证刷新失败，HTTP: \(code)")
                    if code >= 400 && code < 500 {
                        expired = true
                        self?.auth = nil
                    }
                    if debugMode {
                        NSLog("QuotaPing quota: 刷新失败 HTTP \(code) \(err?.localizedDescription ?? "")")
                    }
                }
                done(ok, expired)
            }
        }.resume()
    }
}

// MARK: - 帮助

struct HelpFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 52, height: 52)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 3) {
                    Text("QuotaPing")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("在菜单栏同时查看 AI 额度和网络状态")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 14) {
                HelpFeatureRow(
                    icon: "clock.arrow.circlepath",
                    title: "5h 与 1w 额度",
                    detail: "5h 显示下次重置时间和剩余百分比；1w 显示重置星期和剩余百分比。"
                )
                HelpFeatureRow(
                    icon: "network",
                    title: "Google 连通状态",
                    detail: "勾表示连接正常，··· 表示响应过慢，叉表示连接超时，横线表示其他异常。"
                )
                HelpFeatureRow(
                    icon: "arrow.clockwise",
                    title: "自动更新",
                    detail: "程序会定时刷新。也可以在菜单中立即刷新，并分别调整连通和额度刷新频率。"
                )
                HelpFeatureRow(
                    icon: "doc.text.magnifyingglass",
                    title: "网络日志",
                    detail: "连接失败和响应过慢会记录在本机，可从菜单打开查看，最多保留 1000 条。"
                )
            }
            .padding(16)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

            Text("所有状态都显示在菜单栏；点击图标可查看详情与设置。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 500)
    }
}

final class HelpWindowController {
    private let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 405),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotaPing 帮助"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HelpView())
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 应用内网络日志

struct NetworkLogView: View {
    @ObservedObject var ping: ReachabilityEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("网络日志")
                        .font(.system(size: 15, weight: .semibold))
                    Text("最近 1000 条 google.com 不可用或响应过慢的检测")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空") { ping.clearFailureLogs() }
                    .disabled(ping.failureLogs.isEmpty)
            }
            .padding(12)

            Divider()

            if ping.failureLogs.isEmpty {
                ContentUnavailableView(
                    "暂无失败记录",
                    systemImage: "checkmark.circle",
                    description: Text("后续连接失败会自动出现在这里")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(ping.failureLogs) { entry in
                            logRow(entry)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
    }

    private func logRow(_ entry: NetworkFailureLog) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)
                Text(entry.reason)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(entry.elapsedMilliseconds) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(entry.url)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

final class NetworkLogWindowController {
    private let window: NSWindow

    init(ping: ReachabilityEngine) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotaPing 网络日志"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NetworkLogView(ping: ping))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 菜单栏

/// 菜单栏横向信息条：连通符号 + 5h 双行额度 + 1w 双行额度。
enum StatusIconRenderer {
    private static let size = NSSize(width: 88, height: 22)

    static func image(
        fiveHourPercent: Int?,
        fiveHourResetAt: Date?,
        weeklyPercent: Int?,
        weeklyResetAt: Date?,
        networkState: NetworkIndicatorState
    ) -> NSImage {
        let five = fiveHourPercent.map { max(0, min(100, $0)) }
        let weekly = weeklyPercent.map { max(0, min(100, $0)) }
        
        let hasFive = five != nil
        let hasWeekly = weekly != nil
        let width: CGFloat = (hasFive && hasWeekly) ? 88 : 50
        let size = NSSize(width: width, height: 22)

        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            drawReachability(networkState)
            
            if hasFive && hasWeekly {
                drawQuotaColumn(leftX: 24,
                                topText: fiveHourResetAt.map(timeLabel) ?? "--:--",
                                remaining: five)
                drawDivider()
                drawQuotaColumn(leftX: 59,
                                topText: weeklyResetAt.map(weekdayLabel) ?? "---",
                                remaining: weekly)
            } else if hasWeekly {
                drawQuotaColumn(leftX: 24,
                                topText: weeklyResetAt.map(weekdayLabel) ?? "---",
                                remaining: weekly)
            } else if hasFive {
                drawQuotaColumn(leftX: 24,
                                topText: fiveHourResetAt.map(timeLabel) ?? "--:--",
                                remaining: five)
            } else {
                drawQuotaColumn(leftX: 24, topText: "---", remaining: nil)
            }
            
            return true
        }
        // 作为菜单栏模板图像，由 macOS 根据深浅色和选中状态统一着色。
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(
            fiveHourPercent: five,
            weeklyPercent: weekly,
            networkState: networkState
        )
        return image
    }

    private static func drawReachability(_ state: NetworkIndicatorState) {
        let color = NSColor.labelColor

        let circle = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 3, width: 16, height: 16))
        circle.lineWidth = 1.5
        color.setStroke()
        circle.stroke()

        let symbol = NSBezierPath()
        symbol.lineWidth = 1.9
        symbol.lineCapStyle = .round
        symbol.lineJoinStyle = .round
        switch state {
        case .reachable:
            symbol.move(to: NSPoint(x: 6.2, y: 11.1))
            symbol.line(to: NSPoint(x: 9.3, y: 8.2))
            symbol.line(to: NSPoint(x: 14.9, y: 14.1))
            color.setStroke()
            symbol.stroke()
        case .timedOut:
            symbol.move(to: NSPoint(x: 7.1, y: 7.6))
            symbol.line(to: NSPoint(x: 13.9, y: 14.4))
            symbol.move(to: NSPoint(x: 13.9, y: 7.6))
            symbol.line(to: NSPoint(x: 7.1, y: 14.4))
            color.setStroke()
            symbol.stroke()
        case .slow:
            color.setFill()
            for x in [7.2, 10.5, 13.8] {
                NSBezierPath(ovalIn: NSRect(x: x - 0.8, y: 10.2, width: 1.6, height: 1.6)).fill()
            }
        case .unknown:
            symbol.move(to: NSPoint(x: 7.4, y: 11))
            symbol.line(to: NSPoint(x: 13.6, y: 11))
            color.setStroke()
            symbol.stroke()
        }
    }

    private static func drawQuotaColumn(leftX: CGFloat, topText: String, remaining: Int?) {
        let topFont = NSFont.monospacedDigitSystemFont(ofSize: 7.8, weight: .medium)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 10.8, weight: .semibold)
        drawLeftAligned(topText, leftX: leftX, originY: 12.3, font: topFont,
                        color: NSColor.labelColor.withAlphaComponent(0.72))
        drawLeftAligned(remaining.map { "\($0)%" } ?? "—%",
                        leftX: leftX, originY: 0, font: bottomFont,
                        color: .labelColor)
    }

    private static func drawLeftAligned(
        _ text: String, leftX: CGFloat, originY: CGFloat, font: NSFont, color: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(x: leftX, y: originY,
                       width: measured.width, height: measured.height),
            withAttributes: attributes
        )
    }

    private static func drawCenteredText(
        _ text: String, centerX: CGFloat, originY: CGFloat, font: NSFont, color: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(x: centerX - measured.width / 2, y: originY,
                       width: measured.width, height: measured.height),
            withAttributes: attributes
        )
    }

    private static func drawCenteredColumn(centerX: CGFloat, topText: String, remaining: Int?) {
        let topFont = NSFont.monospacedDigitSystemFont(ofSize: 7.8, weight: .medium)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 10.8, weight: .semibold)
        drawCenteredText(topText, centerX: centerX, originY: 12.3, font: topFont,
                         color: NSColor.labelColor.withAlphaComponent(0.72))
        drawCenteredText(remaining.map { "\($0)%" } ?? "—%",
                         centerX: centerX, originY: 0, font: bottomFont,
                         color: .labelColor)
    }

    private static func drawDivider() {
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: NSRect(x: 54, y: 3.5, width: 1, height: 15)).fill()
    }

    private static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func weekdayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    private static func accessibilityDescription(
        fiveHourPercent: Int?, weeklyPercent: Int?, networkState: NetworkIndicatorState
    ) -> String {
        let five = fiveHourPercent.map { "5 小时剩余 \($0)%" } ?? "5 小时额度未知"
        let weekly = weeklyPercent.map { "周剩余 \($0)%" } ?? "周额度未知"
        let network: String
        switch networkState {
        case .reachable: network = "google.com 可连接"
        case .slow: network = "google.com 响应过慢"
        case .timedOut: network = "google.com 连接超时"
        case .unknown: network = "google.com 状态未知"
        }
        return "\(five)，\(weekly)，\(network)"
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let ping: ReachabilityEngine
    private let quota: QuotaEngine
    private let updaterController: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()
    private var networkIndicator: NetworkIndicatorState = .unknown
    private lazy var logWindow = NetworkLogWindowController(ping: ping)
    private lazy var helpWindow = HelpWindowController()

    init(
        ping: ReachabilityEngine,
        quota: QuotaEngine,
        updaterController: SPUStandardUpdaterController
    ) {
        self.ping = ping
        self.quota = quota
        self.updaterController = updaterController
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.length = 92
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "QuotaPing"
        item.button?.imagePosition = .imageOnly

        Publishers.CombineLatest3(ping.$status, ping.$lastChecked, quota.$status)
            .sink { [weak self] _, _, _ in self?.updateIcon() }
            .store(in: &cancellables)
        updateIcon()
    }

    private func updateIcon() {
        switch ping.status {
        case .ok:
            networkIndicator = .reachable
        case .slow:
            networkIndicator = .slow
        case .fail(let reason):
            networkIndicator = reason == "超时" ? .timedOut : .unknown
        case .idle, .checking:
            break
        }

        var fiveHour: Int?
        var fiveHourResetAt: Date?
        var weekly: Int?
        var weeklyResetAt: Date?
        if case .ok(_, let five, let week, _) = quota.status {
            fiveHour = five?.remainingPercent
            fiveHourResetAt = five?.resetAt
            weekly = week?.remainingPercent
            weeklyResetAt = week?.resetAt
        }

        let image = StatusIconRenderer.image(
            fiveHourPercent: fiveHour,
            fiveHourResetAt: fiveHourResetAt,
            weeklyPercent: weekly,
            weeklyResetAt: weeklyResetAt,
            networkState: networkIndicator
        )
        item.button?.title = ""
        item.button?.image = image
        item.length = image.size.width + 4
        item.button?.toolTip = image.accessibilityDescription
    }

    // MARK: 菜单（每次打开时重建，保证状态新鲜）

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(googleLine))
        for line in chatgptLines { menu.addItem(disabled(line)) }
        menu.addItem(.separator())

        let pingMenu = NSMenu()
        for (label, v) in [("5 秒", 5.0), ("15 秒", 15), ("30 秒", 30),
                           ("1 分钟", 60), ("5 分钟", 300)] {
            let it = NSMenuItem(title: label,
                                action: #selector(setPingInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            it.state = abs(Prefs.pingInterval - v) < 0.5 ? .on : .off
            pingMenu.addItem(it)
        }
        menu.addItem(submenuItem("连通检测频率", pingMenu))

        let quotaMenu = NSMenu()
        for (label, v) in [("30 秒", 30.0), ("1 分钟", 60), ("5 分钟", 300), ("15 分钟", 900)] {
            let it = NSMenuItem(title: label,
                                action: #selector(setQuotaInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            it.state = abs(Prefs.quotaInterval - v) < 0.5 ? .on : .off
            quotaMenu.addItem(it)
        }
        menu.addItem(submenuItem("额度刷新频率", quotaMenu))

        let now = NSMenuItem(title: "立即刷新",
                             action: #selector(refreshNow), keyEquivalent: "r")
        now.target = self
        menu.addItem(now)

        let logs = NSMenuItem(title: "查看网络日志…",
                              action: #selector(showNetworkLogs), keyEquivalent: "l")
        logs.target = self
        menu.addItem(logs)

        let exportLogs = NSMenuItem(title: "导出运行日志…",
                                    action: #selector(exportAppLogs), keyEquivalent: "e")
        exportLogs.target = self
        menu.addItem(exportLogs)

        menu.addItem(.separator())
        let updates = NSMenuItem(
            title: "检查更新…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = updaterController
        updates.isEnabled = updaterController.updater.canCheckForUpdates
        menu.addItem(updates)

        let help = NSMenuItem(title: "帮助",
                              action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        menu.addItem(help)

        let quit = NSMenuItem(title: "退出 QuotaPing",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    private var googleLine: String {
        switch ping.status {
        case .idle: return "google.com：待检测"
        case .checking: return "google.com：检测中…"
        case .ok(let rtt): return "google.com：正常（\(Int(rtt.rounded()))ms）"
        case .slow(let rtt): return "google.com：不稳定（\(Int(rtt.rounded()))ms，浏览器可能无法打开）"
        case .fail(let r): return "google.com：不可达（\(r)）"
        }
    }

    private var chatgptLines: [String] {
        switch quota.status {
        case .idle: return ["ChatGPT 额度：待检测"]
        case .loading: return ["ChatGPT 额度：加载中…"]
        case .unavailable(let r): return ["ChatGPT 额度：\(r)"]
        case .ok(let plan, let five, let week, let credits):
            var lines = ["ChatGPT（\(plan)）："]
            if let five {
                lines.append("5 小时：剩 \(five.remainingPercent)% · \(resetLabel(five.resetAt))")
            }
            if let week {
                lines.append("每周：剩 \(week.remainingPercent)% · \(resetLabel(week.resetAt))")
            }
            if let credits, credits > 0 { lines.append("credits：\(Int(credits))") }
            if five == nil && week == nil { lines.append("（接口未返回限额数据）") }
            return lines
        }
    }

    @objc private func setPingInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Prefs.pingInterval = v
        ping.start(interval: v)
    }

    @objc private func setQuotaInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Prefs.quotaInterval = v
        quota.start(interval: v)
    }

    @objc private func refreshNow() {
        ping.check()
        quota.fetchNow()
    }

    @objc private func showNetworkLogs() {
        logWindow.show()
    }

    @objc private func exportAppLogs() {
        let panel = NSSavePanel()
        panel.title = "导出 QuotaPing 运行日志"
        panel.nameFieldStringValue = "QuotaPing_\(Int(Date().timeIntervalSince1970)).log"
        panel.allowedContentTypes = [.log, .plainText]
        panel.canCreateDirectories = true
        
        NSApp.activate(ignoringOtherApps: true)
        
        if panel.runModal() == .OK, let url = panel.url {
            if FileManager.default.fileExists(atPath: AppLogger.logURL.path) {
                try? FileManager.default.copyItem(at: AppLogger.logURL, to: url)
            } else {
                try? "暂无日志记录\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    @objc func showHelp() {
        helpWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    let ping = ReachabilityEngine()
    let quota = QuotaEngine()
    private var statusBar: StatusBarController!
    private var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ note: Notification) {
        AppLogger.log("App 启动: QuotaPing")
        NSApp.setActivationPolicy(.accessory)
        Prefs.migrateLegacyDefaultsIfNeeded()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        statusBar = StatusBarController(
            ping: ping,
            quota: quota,
            updaterController: updaterController
        )

        // 连通探测失败时跳过本轮额度请求（不白打认证接口）
        quota.isOnline = { [weak self] in
            switch self?.ping.status {
            case .fail: return false
            default: return true
            }
        }

        ping.start(interval: Prefs.pingInterval)
        quota.start(interval: Prefs.quotaInterval)

        if !Prefs.hasShownHelp {
            Prefs.hasShownHelp = true
            DispatchQueue.main.async { [weak self] in self?.statusBar.showHelp() }
        }

        if debugMode { NSLog("QuotaPing 启动完成（调试模式）") }
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
