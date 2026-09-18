// QuotaPing.swift
// macOS 菜单栏工具：google.com 连通检测 + ChatGPT 额度（5 小时 / 每周）
// 单文件实现。构建：bash build.sh
// 调试：QUOTAPING_DEBUG=1 运行时向统一日志输出状态

import AppKit
import SwiftUI
import Combine
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

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case exited(String)
    case timedOut
    case invalidResponse
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 Codex，请安装或更新 ChatGPT/Codex"
        case .launchFailed(let detail):
            return "Codex 服务启动失败：\(detail)"
        case .exited(let detail):
            return detail.isEmpty ? "Codex 服务已退出" : "Codex 服务已退出：\(detail)"
        case .timedOut:
            return "Codex 服务响应超时"
        case .invalidResponse:
            return "Codex 服务响应格式异常"
        case .rpc(let message):
            let lower = message.lowercased()
            if lower.contains("unauthorized") || lower.contains("auth") || lower.contains("login") {
                return "Codex 登录已过期，请在 ChatGPT/Codex 中重新登录"
            }
            return "Codex 服务错误：\(message)"
        }
    }
}

struct CodexRateLimitResult {
    let account: [String: Any]?
    let limits: [String: Any]
}

/// 对官方 `codex app-server` 做一次短连接 JSON-RPC 查询。
/// 认证、token 刷新和上游额度请求均由 Codex 负责，QuotaPing 不接触登录凭据。
final class CodexRateLimitRequest {
    typealias Completion = (Result<CodexRateLimitResult, Error>) -> Void

    private let executableURL: URL
    private let completion: Completion
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var account: [String: Any]?
    private var accountReadCompleted = false
    private var limits: [String: Any]?
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(executableURL: URL, completion: @escaping Completion) {
        self.executableURL = executableURL
        self.completion = completion
    }

    func start() {
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveError(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                let detail = self.safeErrorText()
                self.finish(.failure(CodexAppServerError.exited(detail)))
            }
        }

        do {
            try process.run()
        } catch {
            finish(.failure(CodexAppServerError.launchFailed(error.localizedDescription)))
            return
        }

        send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "quotaping",
                    "title": "QuotaPing",
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "unknown",
                ]
            ],
        ])

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(CodexAppServerError.timedOut))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func cancel() {
        finish(.failure(CodexAppServerError.exited("查询已取消")))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.outputBuffer.append(data)
            while let newline = self.outputBuffer.firstIndex(of: 0x0A) {
                let line = self.outputBuffer.prefix(upTo: newline)
                self.outputBuffer.removeSubrange(...newline)
                self.handleLine(Data(line))
            }
        }
    }

    private func receiveError(_ data: Data) {
        guard !data.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.errorBuffer.append(data)
            if self.errorBuffer.count > 4096 {
                self.errorBuffer.removeFirst(self.errorBuffer.count - 4096)
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let error = message["error"] as? [String: Any] {
            let text = (error["message"] as? String) ?? "未知 JSON-RPC 错误"
            finish(.failure(CodexAppServerError.rpc(text)))
            return
        }

        guard let id = (message["id"] as? NSNumber)?.intValue else { return }
        switch id {
        case 0:
            send(["method": "initialized", "params": [:]])
            send([
                "method": "account/read",
                "id": 1,
                "params": ["refreshToken": false],
            ])
            send(["method": "account/rateLimits/read", "id": 2])
        case 1:
            if let result = message["result"] as? [String: Any] {
                account = result["account"] as? [String: Any]
            }
            accountReadCompleted = true
            completeIfReady()
        case 2:
            guard let result = message["result"] as? [String: Any] else {
                finish(.failure(CodexAppServerError.invalidResponse))
                return
            }
            limits = result
            completeIfReady()
        default:
            break
        }
    }

    private func completeIfReady() {
        guard accountReadCompleted, let limits else { return }
        finish(.success(CodexRateLimitResult(account: account, limits: limits)))
    }

    private func send(_ object: [String: Any]) {
        guard !finished,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            finish(.failure(CodexAppServerError.exited(error.localizedDescription)))
        }
    }

    private func safeErrorText() -> String {
        let raw = String(data: errorBuffer, encoding: .utf8) ?? ""
        return raw
            .split(whereSeparator: { $0.isNewline })
            .suffix(2)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finish(_ result: Result<CodexRateLimitResult, Error>) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        completion(result)
    }
}

final class QuotaEngine: ObservableObject {
    @Published private(set) var status: QuotaStatus = .idle

    private var timer: Timer?
    private var request: CodexRateLimitRequest?
    private var hasLoaded = false

    /// 由 AppDelegate 注入：连通探测失败时跳过本轮额度请求
    var isOnline: () -> Bool = { true }

    func start(interval: Double) {
        timer?.invalidate()
        fetch()
        let t = Timer.scheduledTimer(withTimeInterval: max(interval, 30), repeats: true) { [weak self] _ in
            self?.fetch()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func fetchNow() { fetch() }

    private func fetch() {
        guard request == nil else { return }
        guard isOnline() else { return }
        guard let executable = Self.codexExecutableURL() else {
            status = .unavailable(reason: CodexAppServerError.executableNotFound.localizedDescription)
            return
        }
        if !hasLoaded { status = .loading }

        let operation = CodexRateLimitRequest(executableURL: executable) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.request = nil
                switch result {
                case .success(let payload):
                    self.handle(payload)
                case .failure(let error):
                    let reason = error.localizedDescription
                    AppLogger.log("额度刷新失败：\(reason)")
                    if !self.hasLoaded { self.status = .unavailable(reason: reason) }
                    if debugMode { NSLog("QuotaPing quota: \(reason)") }
                }
            }
        }
        request = operation
        operation.start()
    }

    private static func codexExecutableURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["QUOTAPING_CODEX_PATH"],
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private func handle(_ payload: CodexRateLimitResult) {
        let result = payload.limits
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let codexBucket = byID?["codex"] as? [String: Any]
        guard let bucket = codexBucket ?? result["rateLimits"] as? [String: Any] else {
            status = .unavailable(reason: "Codex 未返回额度信息")
            return
        }

        struct ParsedWindow {
            let durationMinutes: Int
            let quota: QuotaWindow
        }
        func parseWindow(_ value: Any?) -> ParsedWindow? {
            guard let object = value as? [String: Any],
                  let used = (object["usedPercent"] as? NSNumber)?.doubleValue,
                  let duration = (object["windowDurationMins"] as? NSNumber)?.intValue,
                  let reset = (object["resetsAt"] as? NSNumber)?.doubleValue else { return nil }
            return ParsedWindow(
                durationMinutes: duration,
                quota: QuotaWindow(
                    usedPercent: Int(used.rounded()),
                    resetAt: Date(timeIntervalSince1970: reset)
                )
            )
        }

        let windows = [parseWindow(bucket["primary"]), parseWindow(bucket["secondary"])]
            .compactMap { $0 }
        let five = windows.first(where: { $0.durationMinutes == 5 * 60 })
            ?? windows.filter({ $0.durationMinutes < 24 * 60 })
                .min(by: { $0.durationMinutes < $1.durationMinutes })
        let week = windows.first(where: { $0.durationMinutes == 7 * 24 * 60 })
            ?? windows.filter({ $0.durationMinutes >= 24 * 60 })
                .max(by: { $0.durationMinutes < $1.durationMinutes })

        let plan = (payload.account?["planType"] as? String)
            ?? (bucket["planType"] as? String)
            ?? "unknown"
        let credits = Self.creditBalance(bucket["credits"] ?? result["credits"])
        status = .ok(
            plan: plan,
            fiveHour: five?.quota,
            weekly: week?.quota,
            credits: credits
        )
        hasLoaded = true
        if debugMode { NSLog("QuotaPing quota: \(status.debugDescription)") }
    }

    private static func creditBalance(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else { return nil }
        for key in ["balance", "remaining", "available"] {
            if let number = object[key] as? NSNumber { return number.doubleValue }
        }
        return nil
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
                    detail: "额度通过官方 Codex 本地服务读取；程序会定时刷新，也可以在菜单中立即刷新。"
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
                lines.append("1周：剩 \(week.remainingPercent)% · \(resetLabel(week.resetAt))")
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
    private var updateCheckTimer: Timer?

    private func setupCustomUpdateChecker() {
        checkCustomUpdate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 172800, repeats: true) { [weak self] _ in
            self?.checkCustomUpdate()
        }
    }

    private func checkCustomUpdate() {
        guard let url = URL(string: "https://raw.githubusercontent.com/gordonbeijing/QuotaPing/main/appcast.xml") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data, let xml = String(data: data, encoding: .utf8) else { return }
            if let range = xml.range(of: "sparkle:version=\"") {
                let sub = xml[range.upperBound...]
                if let endRange = sub.range(of: "\"") {
                    let version = String(sub[..<endRange.lowerBound])
                    DispatchQueue.main.async {
                        self?.handleDiscoveredVersion(version)
                    }
                }
            }
        }.resume()
    }

    private func handleDiscoveredVersion(_ version: String) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard version.compare(current, options: .numeric) == .orderedDescending else { return }
        
        let prompted = UserDefaults.standard.string(forKey: "LastPromptedUpdateVersion")
        if prompted != version {
            UserDefaults.standard.set(version, forKey: "LastPromptedUpdateVersion")
            updaterController.checkForUpdates(nil)
        }
    }

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
        setupCustomUpdateChecker()

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
