import Foundation
import Combine
import JavaScriptCore
import Security
import CryptoKit

struct NaverAPIResult: Decodable, Identifiable {
    var id: String { capture.selectionKey }
    var capture: NaverPlaceCapture
    var category: String
}
struct NaverAPIQuota: Decodable {
    var provider: String
    var limit: Int
    var used: Int
    var remaining: Int
    var blocked: Bool
    var resetMillis: Double
    var inGrace: Bool
}
private struct NaverQuotaAccount: Codable {
    var period: String
    var used: Int
    var blocked: Bool
    var resetMillis: Double
    var lastTrustedMs: Double
}
private struct NaverQuotaLedger: Codable {
    var version = 1
    var accounts: [String: NaverQuotaAccount] = [:]
}
private struct NaverQuotaChange: Decodable {
    var ledger: NaverQuotaLedger
    var quota: NaverAPIQuota
}
private struct NaverSecureState: Codable {
    var version = 1
    var searchID = ""
    var searchSecret = ""
    var mapsID = ""
    var mapsSecret = ""
    var mapsFreeConfirmed = false
    var ledger = NaverQuotaLedger()
}
private struct NaverAPIEnvelope<T: Decodable>: Decodable {
    var ok: Bool
    var value: T?
    var message: String?
}
enum NaverAPIBridge {
    static func call<T: Decodable>(_ method: String, _ input: [String: Any], as type: T.Type) throws -> T {
        guard let context = JSContext() else { throw PlannerFailure.message("네이버 API 처리기를 열지 못했습니다.") }
        context.evaluateScript(NaverPlaceEngineSource.source)
        context.evaluateScript(NaverAPIEngineSource.source)
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "API 처리 오류") }
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let value = context.objectForKeyedSubscript("DeliveryNaverAPI")?.invokeMethod(method + "JSON", withArguments: [String(decoding: data, as: UTF8.self)])
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "API 처리 오류") }
        guard let string = value?.toString(), let output = string.data(using: .utf8) else { throw PlannerFailure.message("API 결과를 읽지 못했습니다.") }
        let result = try JSONDecoder().decode(NaverAPIEnvelope<T>.self, from: output)
        guard result.ok, let value = result.value else { throw PlannerFailure.message(result.message ?? "API 처리 실패") }
        return value
    }
}
private enum NaverAPIKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "kr.deliverytools.routeprobe.naver-api", kSecAttrAccount as String: "state-v1"]
    }
    static func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw PlannerFailure.message("네이버 키·사용량 보관함을 읽지 못했습니다. (\(status))") }
        return data
    }
    static func write(_ data: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PlannerFailure.message("사용량을 저장하지 못해 네이버 요청을 차단했습니다. (\(status))") }
    }
}
private final class NaverAPINetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class NaverAPIStore: ObservableObject {
    static let shared = NaverAPIStore()
    @Published private(set) var hasSearchKeys = false
    @Published private(set) var hasMapsKeys = false
    @Published private(set) var mapsFreeConfirmed = false
    @Published private(set) var isBusy = false
    @Published private(set) var quotas: [String: NaverAPIQuota] = [:]
    @Published var errorMessage: String?
    @Published private(set) var message = "네이버 API 키를 설정하면 지도를 열지 않고 검색·좌표 변환을 사용할 수 있습니다."
    private var state = NaverSecureState()
    private var recoveryBlocked = false
    private var clocks: [String: (milliseconds: Double, uptime: TimeInterval)] = [:]
    private var cooldowns: [String: TimeInterval] = [:]
    private var resolved: [String: (capture: NaverPlaceCapture, uptime: TimeInterval)] = [:]
    private let writeState: (Data) throws -> Void
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let delegate = NaverAPINetworkDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private convenience init() {
        self.init(read: { try NaverAPIKeychain.read() }, write: { try NaverAPIKeychain.write($0) }, transport: nil)
    }
    // Inject storage and transport for native failure/billing-boundary checks.
    init(read: () throws -> Data?, write: @escaping (Data) throws -> Void,
         transport: ((URLRequest) async throws -> (Data, URLResponse))?) {
        writeState = write; self.transport = transport
        do {
            if let data = try read() {
                guard data.count <= 2_000_000 else { throw PlannerFailure.message("보관함 크기를 확인해 주세요.") }
                state = try JSONDecoder().decode(NaverSecureState.self, from: data)
                guard state.version == 1, state.ledger.version == 1 else { throw PlannerFailure.message("보관함 버전을 확인해 주세요.") }
            }
            publish()
            for provider in ["search", "maps"] {
                if let account = state.ledger.accounts[key(provider)] {
                    quotas[provider] = try quotaChange("refresh", provider: provider, now: account.lastTrustedMs).quota
                }
            }
        } catch { recoveryBlocked = true; errorMessage = "기존 키·사용량 기록 오류로 네이버 API 호출을 차단했습니다. \(error.localizedDescription)" }
    }
    private func publish() {
        hasSearchKeys = !state.searchID.isEmpty && !state.searchSecret.isEmpty
        hasMapsKeys = !state.mapsID.isEmpty && !state.mapsSecret.isEmpty
        mapsFreeConfirmed = state.mapsFreeConfirmed
    }
    private func key(_ provider: String) -> String {
        if provider == "maps" { return "maps-free" } // Account free allowance is shared across Maps apps.
        return "search:" + SHA256.hash(data: Data(state.searchID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func commit(_ next: NaverSecureState) throws {
        guard !recoveryBlocked else { throw PlannerFailure.message("보관함 오류를 해결하기 전에는 요청할 수 없습니다.") }
        try writeState(JSONEncoder().encode(next))
        state = next; publish()
    }
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let transport { return try await transport(request) }
        return try await session.data(for: request)
    }
    private func quotaChange(_ method: String, provider: String, now: Double, extra: [String: Any] = [:]) throws -> NaverQuotaChange {
        var input: [String: Any] = ["ledger": try TMapBridge.object(state.ledger), "key": key(provider), "provider": provider, "now": now, "freeConfirmed": state.mapsFreeConfirmed]
        extra.forEach { input[$0.key] = $0.value }
        return try NaverAPIBridge.call(method, input, as: NaverQuotaChange.self)
    }
    private func saveQuota(_ change: NaverQuotaChange) throws {
        var next = state; next.ledger = change.ledger; try commit(next)
        quotas[change.quota.provider] = change.quota
    }
    @discardableResult
    func saveSettings(searchID: String, searchSecret: String, mapsID: String, mapsSecret: String, freeConfirmed: Bool) -> Bool {
        guard !isBusy else { return false }
        do {
            var next = state
            func update(_ enteredID: String, _ enteredSecret: String, _ id: inout String, _ secret: inout String) throws {
                let a = enteredID.trimmingCharacters(in: .whitespacesAndNewlines), b = enteredSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                for value in [a, b] { if !value.isEmpty && (value.utf8.count > 512 || value.contains(where: { $0.isWhitespace || $0.isNewline }) || value.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 })) { throw PlannerFailure.message("API 키 형식을 확인해 주세요.") } }
                if !a.isEmpty && a != id && b.isEmpty { throw PlannerFailure.message("Client ID를 바꿀 때는 해당 Client Secret도 입력해 주세요.") }
                if !a.isEmpty { id = a }; if !b.isEmpty { secret = b }
                if id.isEmpty != secret.isEmpty { throw PlannerFailure.message("Client ID와 Client Secret을 함께 입력해 주세요.") }
            }
            try update(searchID, searchSecret, &next.searchID, &next.searchSecret)
            try update(mapsID, mapsSecret, &next.mapsID, &next.mapsSecret)
            next.mapsFreeConfirmed = freeConfirmed
            try commit(next); resolved.removeAll(); clocks.removeAll(); quotas.removeAll(); errorMessage = nil
            message = "네이버 설정을 저장했습니다. 기존 사용량 기록은 유지합니다."
            Task { await refreshQuotas() }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private func trustedTime(_ provider: String) async throws -> Double {
        if let clock = clocks[provider] {
            let elapsed = ProcessInfo.processInfo.systemUptime - clock.uptime
            if elapsed >= 0 && elapsed < 300 { return clock.milliseconds + elapsed * 1000 }
        }
        let host = provider == "search" ? "openapi.naver.com" : "maps.apigw.ntruss.com"
        var request = URLRequest(url: URL(string: "https://\(host)/")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"; request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode), http.url?.host == host, http.url?.scheme == "https",
              (Int(http.value(forHTTPHeaderField: "Age") ?? "0") ?? 999) <= 30,
              let header = http.value(forHTTPHeaderField: "Date") else { throw PlannerFailure.message("네이버 서버 기준 시간을 확인하지 못했습니다. 인터넷 연결 후 다시 시도해 주세요.") }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = format.date(from: header) else { throw PlannerFailure.message("서버 기준 시간을 읽지 못했습니다.") }
        let now = date.timeIntervalSince1970 * 1000
        clocks[provider] = (now, ProcessInfo.processInfo.systemUptime)
        return now
    }
    func refreshQuotas() async {
        guard !isBusy, !recoveryBlocked else { return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        for provider in ["search", "maps"] where (provider == "search" ? hasSearchKeys : hasMapsKeys) {
            do { try saveQuota(quotaChange("refresh", provider: provider, now: try await trustedTime(provider))) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func raiseUsage(provider: String, used: Int) async {
        guard !isBusy, ["search", "maps"].contains(provider) else { return }
        isBusy = true; defer { isBusy = false }
        do { try saveQuota(quotaChange("raise", provider: provider, now: try await trustedTime(provider), extra: ["used": used])); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func fetch(_ provider: String, query: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !recoveryBlocked else { throw PlannerFailure.message(errorMessage ?? "사용량 보관함 오류로 요청을 차단했습니다.") }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2000, !trimmed.unicodeScalars.contains(where: { $0.value < 32 }) else { throw PlannerFailure.message("검색어·주소를 확인해 주세요.") }
        guard provider == "search" ? hasSearchKeys : hasMapsKeys else { throw PlannerFailure.message("네이버 API 설정에서 Client ID와 Client Secret을 입력해 주세요.") }
        if let until = cooldowns[provider], until > ProcessInfo.processInfo.systemUptime {
            throw PlannerFailure.message("네이버의 일시 호출 제한으로 \(Int(ceil(until - ProcessInfo.processInfo.systemUptime)))초 뒤 다시 사용할 수 있습니다.")
        }
        let now = try await trustedTime(provider)
        let host = provider == "search" ? "openapi.naver.com" : "maps.apigw.ntruss.com"
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host
        parts.path = provider == "search" ? "/v1/search/local.json" : "/map-geocode/v2/geocode"
        parts.queryItems = provider == "search" ? [URLQueryItem(name: "query", value: trimmed), URLQueryItem(name: "display", value: "5"), URLQueryItem(name: "start", value: "1"), URLQueryItem(name: "sort", value: "random")] : [URLQueryItem(name: "query", value: trimmed), URLQueryItem(name: "count", value: "100")]
        guard let url = parts.url, url.host == host else { throw PlannerFailure.message("공식 API 요청을 준비하지 못했습니다.") }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(provider == "search" ? state.searchID : state.mapsID, forHTTPHeaderField: provider == "search" ? "X-Naver-Client-Id" : "x-ncp-apigw-api-key-id")
        request.setValue(provider == "search" ? state.searchSecret : state.mapsSecret, forHTTPHeaderField: provider == "search" ? "X-Naver-Client-Secret" : "x-ncp-apigw-api-key")
        try Task.checkCancellation()
        try saveQuota(quotaChange("reserve", provider: provider, now: now)) // Persist before dispatch. No refund on failure/cancellation.
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, http.url?.host == host, http.url?.scheme == "https" else { throw PlannerFailure.message("네이버 API 응답 주소를 확인하지 못했습니다.") }
        guard data.count <= 1_000_000 else { throw PlannerFailure.message("네이버 API 응답이 너무 큽니다.") }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode != 200 {
            let cloudError = body["error"] as? [String: Any]
            let code = String(describing: body["errorCode"] ?? cloudError?["errorCode"] ?? "")
            let detail = String(describing: body["errorMessage"] ?? cloudError?["message"] ?? "").lowercased()
            if http.statusCode == 429, code != "012", ["410", "420"].contains(code) || detail.contains("throttle") || detail.contains("rate limit") || detail.contains("초당") {
                let delay = min(60, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30))
                cooldowns[provider] = ProcessInfo.processInfo.systemUptime + delay
                throw PlannerFailure.message("네이버의 일시 호출 제한입니다. \(Int(delay))초 뒤 다시 시도해 주세요. 무료 기간 한도는 소진된 것으로 처리하지 않습니다.")
            }
            if http.statusCode == 429 || code == "012" || detail.contains("quota") || detail.contains("한도") {
                try saveQuota(quotaChange("block", provider: provider, now: now))
                throw PlannerFailure.message(provider == "maps" ? "Maps 서버가 할당량을 제한했습니다. 콘솔에서 Geocoding 사용 선택과 할당량을 확인해 주세요. 다음 초기화까지 요청을 차단합니다." : "네이버 서버가 호출을 제한했습니다. 다음 초기화까지 요청을 차단합니다.")
            }
            if [401, 403].contains(http.statusCode) { throw PlannerFailure.message("네이버 인증·권한을 확인해 주세요. 검색 키와 새 Maps 키는 서로 다릅니다. (HTTP \(http.statusCode))") }
            throw PlannerFailure.message("네이버 API 요청에 실패했습니다. (HTTP \(http.statusCode))")
        }
        guard !body.isEmpty else { throw PlannerFailure.message("네이버 API JSON 응답을 읽지 못했습니다.") }
        return body
    }
    func search(_ query: String) async throws -> [NaverAPIResult] {
        guard !isBusy else { throw PlannerFailure.message("진행 중인 네이버 요청이 끝난 뒤 다시 시도해 주세요.") }
        isBusy = true; defer { isBusy = false }
        let response = try await fetch("search", query: query)
        return try NaverAPIBridge.call("local", ["response": response, "now": Date().timeIntervalSince1970 * 1000], as: [NaverAPIResult].self)
    }
    func address(_ address: String, name: String) async throws -> NaverPlaceCapture {
        let capture = try NaverAPIBridge.call("seed", ["name": name, "address": address, "now": Date().timeIntervalSince1970 * 1000], as: NaverPlaceCapture.self)
        return try await resolve(capture)
    }
    func resolve(_ capture: NaverPlaceCapture) async throws -> NaverPlaceCapture {
        _ = try NaverPlaceBridge.call("validate", ["capture": try TMapBridge.object(capture)], as: NaverPlaceCapture.self)
        let cacheKey = SHA256.hash(data: try JSONEncoder().encode([capture.selectionKey, capture.name, capture.address, capture.roadAddress, capture.jibunAddress])).map { String(format: "%02x", $0) }.joined()
        if let cached = resolved[cacheKey], ProcessInfo.processInfo.systemUptime - cached.uptime < 3600 {
            var value = cached.capture; value.sourceURL = capture.sourceURL; value.capturedAt = capture.capturedAt
            return value
        }
        guard !isBusy else { throw PlannerFailure.message("진행 중인 네이버 요청이 끝난 뒤 다시 시도해 주세요.") }
        isBusy = true; defer { isBusy = false }
        let value: NaverPlaceCapture
        if hasMapsKeys && mapsFreeConfirmed {
            let response = try await fetch("maps", query: capture.preferredAddress)
            value = try NaverAPIBridge.call("geocode", ["capture": try TMapBridge.object(capture), "response": response], as: NaverPlaceCapture.self)
        } else if hasSearchKeys {
            let response = try await fetch("search", query: capture.name + " " + capture.preferredAddress)
            let results = try NaverAPIBridge.call("local", ["response": response, "now": Date().timeIntervalSince1970 * 1000], as: [NaverAPIResult].self)
            value = try NaverAPIBridge.call("choose", ["capture": try TMapBridge.object(capture), "results": try results.map { ["capture": try TMapBridge.object($0.capture), "category": $0.category] }], as: NaverPlaceCapture.self)
        } else { throw PlannerFailure.message("네이버 API 설정에서 새 Maps의 Geocoding 키와 무료 대표 계정 여부를 등록해 주세요. 지도를 표시할 필요는 없습니다.") }
        if resolved.count > 200 { resolved.removeAll() }; resolved[cacheKey] = (value, ProcessInfo.processInfo.systemUptime)
        return value
    }
}
