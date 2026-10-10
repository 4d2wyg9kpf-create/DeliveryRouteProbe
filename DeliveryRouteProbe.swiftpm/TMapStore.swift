import Foundation
import Combine
import Security
import CryptoKit

private struct TMapSecureState: Codable {
    var appKey = ""
    var freePlanConfirmed = false
    var ledger = TMapQuotaLedger()
    var options = TMapOptions()
}

private enum TMapKeychain {
    private static let service = "kr.deliverytools.routeprobe.tmap"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "state-v1"]
    }
    @MainActor private static let archive = APICredentialArchive(
        readPrimary: { try readKeychain() }, writePrimary: { try writeKeychain($0) },
        readProtected: { try APIProtectedStateFile(.tmap).read() },
        writeProtected: { try APIProtectedStateFile(.tmap).write($0) },
        validate: { try TMapStore.validateSavedState($0) })
    @MainActor static func read() throws -> Data? { try archive.read() }
    @MainActor static func write(_ data: Data) throws { try archive.write(data) }
    private static func readKeychain() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PlannerFailure.message("앱키·사용량 보관함을 열지 못했습니다. (\(status))") }
        return data
    }
    private static func writeKeychain(_ data: Data) throws {
        let updates = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PlannerFailure.message("사용량을 저장하지 못해 요청을 차단했습니다. (\(status))") }
    }
}

// No redirects: never forward an appKey or repeat a POST to a redirected endpoint.
private final class TMapNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class TMapStore: ObservableObject {
    // One gate for every scene/window, including concurrent taps.
    static let shared = TMapStore()
    @Published private(set) var quotas: [TMapQuota] = []
    @Published private(set) var options = TMapOptions()
    @Published private(set) var freePlanConfirmed = false
    @Published private(set) var hasAppKey = false
    @Published private(set) var isOptimizing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var route: TMapRoute?
    @Published private(set) var message = "Free 상품의 앱키를 등록하고 하역 위치를 확인해 주세요."
    @Published var errorMessage: String?
    private var state = TMapSecureState()
    private var recoveryBlocked = false
    private var referenceMillis: Double?
    private var referenceUptime: TimeInterval?
    private var optimizationTask: Task<Void, Never>?
    private var requestedPlan: Data?
    private let writeState: (Data) throws -> Void
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let delegate = TMapNetworkDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private convenience init() {
        self.init(read: { try TMapKeychain.read() }, write: { try TMapKeychain.write($0) }, transport: nil)
    }
    init(read: () throws -> Data?, write: @escaping (Data) throws -> Void,
         transport: ((URLRequest) async throws -> (Data, URLResponse))?) {
        writeState = write; self.transport = transport
        do {
            if let data = try read() {
                guard data.count <= 2_000_000 else { throw APICredentialStorageError.invalid }
                state = try JSONDecoder().decode(TMapSecureState.self, from: data)
                guard state.ledger.version == 1 else { throw APICredentialStorageError.invalid }
            }
            publishSettings()
            if hasAppKey, let account = state.ledger.accounts[keyID] {
                // Show the saved balance. Do not reset it from the device's calendar.
                let result = try quotaCall("refresh", now: account.lastTrustedMs)
                quotas = result.quotas ?? []
            }
        } catch {
            recoveryBlocked = true
            errorMessage = "앱키·사용량 기록을 읽지 못해 호출을 차단했습니다. \(error.localizedDescription)"
        }
    }
    static func validateSavedState(_ data: Data) throws {
        let state = try JSONDecoder().decode(TMapSecureState.self, from: data)
        guard state.ledger.version == 1 else { throw APICredentialStorageError.invalid }
    }
    private var keyID: String { SHA256.hash(data: Data(state.appKey.utf8)).map { String(format: "%02x", $0) }.joined() }
    var nowMillis: Double? {
        guard let ref = referenceMillis, let uptime = referenceUptime else { return nil }
        return ref + max(0, ProcessInfo.processInfo.systemUptime - uptime) * 1000
    }
    var routeIsValid: Bool {
        guard let route = route, let now = nowMillis else { return false }
        return now < route.expiresAtMillis
    }
    var canRequest: Bool { hasAppKey && freePlanConfirmed && !recoveryBlocked && !isOptimizing && !isRefreshing && nowMillis != nil }
    func quota(for count: Int) -> TMapQuota? {
        guard (1...100).contains(count) else { return nil }
        let api = count <= 10 ? 10 : count <= 20 ? 20 : count <= 30 ? 30 : 100
        return quotas.first { $0.id == api }
    }
    func canApply(to plan: DeliveryPlan) -> Bool {
        guard routeIsValid, let requested = requestedPlan, let current = try? TMapBridge.fingerprintData(plan) else { return false }
        return requested == current
    }
    private func publishSettings() {
        options = state.options
        freePlanConfirmed = state.freePlanConfirmed
        hasAppKey = !state.appKey.isEmpty
    }
    private func commit(_ value: TMapSecureState) throws {
        guard !recoveryBlocked else { throw PlannerFailure.message("기존 사용량 기록 복구가 필요해 요청을 차단했습니다.") }
        try writeState(JSONEncoder().encode(value))
        state = value
        publishSettings()
    }
    private func quotaCall(_ method: String, now: Double, extra: [String: Any] = [:]) throws -> TMapQuotaChange {
        var input: [String: Any] = ["ledger": try TMapBridge.object(state.ledger), "keyID": keyID, "now": now]
        extra.forEach { input[$0.key] = $0.value }
        return try TMapBridge.call(method, input, as: TMapQuotaChange.self)
    }
    private func saveQuota(_ result: TMapQuotaChange) throws {
        var next = state
        next.ledger = result.ledger
        try commit(next)
        if let values = result.quotas { quotas = values }
    }
    func saveSettings(appKey: String, freeConfirmed: Bool, options: TMapOptions) {
        guard !isOptimizing && !isRefreshing else { return }
        do {
            var next = state
            let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                guard key.utf8.count <= 512, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw PlannerFailure.message("앱키 형식을 확인해 주세요.") }
                next.appKey = key
            }
            guard !next.appKey.isEmpty else { throw PlannerFailure.message("앱키를 입력해 주세요.") }
            next.freePlanConfirmed = freeConfirmed
            next.options = options
            // Preserve counters for all prior keys when settings or keys change.
            try commit(next)
            route = nil; requestedPlan = nil; quotas = []
            errorMessage = nil
            message = "티맵 설정을 저장했습니다. 사용량 기록은 유지됩니다."
            Task { await refreshClock() }
        } catch { errorMessage = error.localizedDescription }
    }
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let transport { return try await transport(request) }
        return try await session.data(for: request)
    }
    private func trustedTime() async throws -> Double {
        var request = URLRequest(url: URL(string: "https://openapi.sk.com/")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode), let text = http.value(forHTTPHeaderField: "Date") else { throw PlannerFailure.message("서버 기준 시각을 확인하지 못해 요청을 보류했습니다. 잠시 후 다시 확인해 주세요.") }
        if let age = http.value(forHTTPHeaderField: "Age"), let seconds = Double(age), seconds > 30 { throw PlannerFailure.message("오래된 기준 시각이 반환돼 요청을 보류했습니다.") }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: text) else { throw PlannerFailure.message("서버 기준 시각을 읽지 못했습니다.") }
        let now = date.timeIntervalSince1970 * 1000
        if hasAppKey { try saveQuota(quotaCall("refresh", now: now)) }
        referenceMillis = now
        referenceUptime = ProcessInfo.processInfo.systemUptime
        return now
    }
    func refreshClock() async {
        guard !isOptimizing && !isRefreshing && !recoveryBlocked else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do { _ = try await trustedTime(); errorMessage = nil; tick() }
        catch { referenceMillis = nil; referenceUptime = nil; errorMessage = error.localizedDescription }
    }
    func tick() {
        guard let now = nowMillis, hasAppKey, !recoveryBlocked else { return }
        do {
            let result = try quotaCall("refresh", now: now)
            let changed = quotas.first?.period != result.quotas?.first?.period
            if changed { try saveQuota(result) }
            else { quotas = result.quotas ?? [] }
            if let route = route, now >= route.expiresAtMillis { self.route = nil; requestedPlan = nil; message = "티맵 결과의 24시간 유효기간이 끝났습니다." }
        } catch { errorMessage = error.localizedDescription }
    }
    func raiseUsed(apiID: Int, used: Int) {
        guard !isOptimizing && !isRefreshing, let now = nowMillis else { return }
        do {
            try saveQuota(quotaCall("raiseUsage", now: now, extra: ["apiID": apiID, "used": used]))
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func optimize(plan: DeliveryPlan) {
        guard !isOptimizing && !isRefreshing && !recoveryBlocked else { return }
        guard hasAppKey && freePlanConfirmed else { errorMessage = "Free 상품의 앱키를 등록해 주세요."; return }
        do {
            // Validate all local inputs before reserving a free request.
            let request = try TMapBridge.call("request", ["plan": try TMapBridge.object(plan), "options": try TMapBridge.object(options)], as: TMapRequest.self)
            let planFingerprint = try TMapBridge.fingerprintData(plan)
            route = nil; requestedPlan = nil
            isOptimizing = true
            errorMessage = nil
            message = "서버 시각과 무료 잔여량을 확인하고 있습니다."
            optimizationTask = Task {
                defer { isOptimizing = false; optimizationTask = nil }
                do {
                    let now = try await trustedTime()
                    try Task.checkCancellation()
                    let reserved = try quotaCall("reserve", now: now, extra: ["apiID": request.apiID, "freePlanConfirmed": state.freePlanConfirmed])
                    try saveQuota(reserved) // A failed save stops execution before URLSession.
                    guard let reservation = reserved.reservation, let url = URL(string: request.url), url.host == "apis.openapi.sk.com", url.scheme == "https" else { throw PlannerFailure.message("티맵 요청을 준비하지 못했습니다.") }
                    try Task.checkCancellation()
                    var networkRequest = URLRequest(url: url)
                    networkRequest.httpMethod = "POST"
                    networkRequest.httpBody = Data(request.body.utf8)
                    networkRequest.setValue(state.appKey, forHTTPHeaderField: "appKey")
                    networkRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    networkRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                    message = "티맵 경유지 최적화 \(request.apiID)를 요청했습니다. 무료 1회 사용을 기록했습니다."
                    let (data, response) = try await send(networkRequest)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse, data.count <= 32_000_000 else { throw PlannerFailure.message("티맵 응답을 읽지 못했습니다.") }
                    let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
                    if !(200..<300).contains(http.statusCode) || ((object as? [String: Any])?["error"] != nil) {
                        let info = try TMapBridge.call("errorInfo", ["status": http.statusCode, "response": object], as: TMapErrorInfo.self)
                        if info.quota {
                            let blocked = try TMapBridge.call("reject", ["ledger": try TMapBridge.object(state.ledger), "reservation": try TMapBridge.object(reservation)], as: TMapQuotaChange.self)
                            try saveQuota(blocked)
                            tick()
                        }
                        throw PlannerFailure.message(info.message.replacingOccurrences(of: state.appKey, with: "[앱키]"))
                    }
                    let fetched = nowMillis ?? now
                    let result = try TMapBridge.call("parse", ["response": object, "request": try TMapBridge.object(request), "plan": TMapBridge.timingPlan(plan), "now": fetched], as: TMapRoute.self)
                    route = result
                    requestedPlan = planFingerprint
                    message = result.warnings.isEmpty ? "티맵 순서를 받았습니다. 기존 배송·적재 조건으로 검증해 계획에 반영할 수 있습니다." : "티맵 순서를 받았습니다. 응답 일정의 확인 사항 \(result.warnings.count)개를 표시했습니다. 배송계획에서 다시 검증하세요."
                } catch {
                    if Task.isCancelled { message = "요청을 중단했습니다. 이미 기록한 사용량은 되돌리지 않습니다." }
                    else { errorMessage = error.localizedDescription.replacingOccurrences(of: state.appKey, with: "[앱키]") }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func cancel() { optimizationTask?.cancel() }
    @discardableResult
    func apply(to planner: PlannerStore) -> Bool {
        do {
            guard canApply(to: planner.plan), let route = route, let now = nowMillis else { throw PlannerFailure.message("계획이 변경됐거나 티맵 결과가 만료됐습니다. 현재 계획을 다시 최적화해 주세요.") }
            let plan = try TMapBridge.call("apply", ["plan": try TMapBridge.object(planner.plan), "route": try TMapBridge.object(route), "now": now], as: DeliveryPlan.self)
            planner.replacePlan(plan)
            planner.calculate()
            message = "티맵 순서를 계획에 연결했습니다. 배송계획의 계산 결과에서 시간·적재·도로 조건을 확인해 주세요."
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
