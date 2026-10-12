import Foundation
import Combine
import Security

struct KakaoSettings: Codable {
    var key = ""
    var mapFreeConfirmed = false
    var naviFreeConfirmed = false
}
private struct KakaoUsage: Codable {
    var used = 0
    var blocked = false
}
private struct KakaoSecureState: Codable {
    var version = 1
    var settings = KakaoSettings()
    var usage: [String: KakaoUsage] = [:]
    var trustedMillis: Double = 0
}
private final class KakaoNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor
final class KakaoRouteStore: ObservableObject {
    static let shared = KakaoRouteStore()
    @Published private(set) var settings = KakaoSettings()
    @Published private(set) var resultCount = 0
    @Published private(set) var results: [KakaoDistanceRecord] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var clock: Date?
    private var state = KakaoSecureState()
    private var blockedRecovery = false
    private var referenceUptime: TimeInterval = 0
    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let resultURL: URL
    private var resultArchive: KakaoDistanceArchive?
    private let delegate = KakaoNetworkDelegate()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 45
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }()
    private convenience init() {
        self.init(read: { try KakaoKeychain.archive.read() }, write: { try KakaoKeychain.archive.write($0) }, transport: nil)
    }
    init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void,
         transport: ((URLRequest) async throws -> (Data, URLResponse))?, directory: URL? = nil) {
        self.read = read; self.write = write; self.transport = transport
        let root = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteProbe")
        resultURL = root.appendingPathComponent("kakao-distances.json")
        do {
            if let data = try read() { try Self.validateSavedState(data); state = try JSONDecoder().decode(KakaoSecureState.self, from: data) }
            resultArchive = try KakaoDistanceArchive(directory: root)
            if FileManager.default.fileExists(atPath: resultURL.path) { let legacy = try DeviceShareCodec.decode([KakaoDistanceRecord].self, Data(contentsOf: resultURL)); try resultArchive!.append(legacy) }
            results = try resultArchive!.recent(); resultCount = try resultArchive!.count
            settings = state.settings
        } catch { blockedRecovery = true; errorMessage = "카카오 키·사용량·결과 기록을 확인하세요. 기존 파일은 보존했습니다." }
    }
    static func validateSavedState(_ data: Data) throws {
        let value = try JSONDecoder().decode(KakaoSecureState.self, from: data)
        guard value.version == 1, value.settings.key.utf8.count <= 200, value.usage.count <= 10_000,
              value.usage.values.allSatisfy({ (0...10_000_000).contains($0.used) }), value.trustedMillis.isFinite, value.trustedMillis >= 0 else { throw APICredentialStorageError.invalid }
    }
    private func commit(_ value: KakaoSecureState, reservations: [String] = []) throws {
        guard !blockedRecovery else { throw APICredentialStorageError.notLoaded }
        let data = try DeviceShareCodec.encode(value); try Self.validateSavedState(data); try write(data)
        state = value; settings = value.settings; try DeviceShareHooks.changed(reservations: reservations)
    }
    func saveSettings(key: String, mapFree: Bool, naviFree: Bool) throws {
        guard !isBusy else { throw PlannerFailure.message("조회가 끝난 뒤 설정을 변경하세요.") }
        var next = state; let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            guard value.range(of: #"^[a-zA-Z0-9_-]{16,200}$"#, options: .regularExpression) != nil else { throw PlannerFailure.message("카카오 REST API 키 형식을 확인하세요.") }
            next.settings.key = value
        }
        next.settings.mapFreeConfirmed = mapFree; next.settings.naviFreeConfirmed = naviFree
        try commit(next); errorMessage = nil
    }
    private var account: String { DeviceShareCodec.key(state.settings.key) }
    private static func period(_ date: Date, monthly: Bool = false) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Seoul"); f.dateFormat = monthly ? "yyyy-MM" : "yyyy-MM-dd"; return f.string(from: date)
    }
    private var now: Date? { clock.map { $0.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime - referenceUptime)) } }
    private func usageID(_ slot: String, period: String) -> String { account + "|" + period + "|" + slot }
    func used(_ mode: KakaoRouteMode) -> Int {
        guard let now else { return state.usage.filter { $0.key.hasPrefix(account + "|") && $0.key.hasSuffix("|" + mode.rawValue) }.map(\.value.used).max() ?? 0 }
        return state.usage[usageID(mode.rawValue, period: Self.period(now))]?.used ?? 0
    }
    func raiseUsage(_ mode: KakaoRouteMode, used: Int) throws {
        guard !isBusy, let now, (0...10_000_000).contains(used) else { throw PlannerFailure.message("인터넷 시각을 확인한 뒤 제공자 사용량을 입력하세요.") }
        var next = state; let id = usageID(mode.rawValue, period: Self.period(now)); var bucket = next.usage[id] ?? KakaoUsage()
        bucket.used = max(bucket.used, used); next.usage[id] = bucket; try commit(next)
    }
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) { if let transport { return try await transport(request) }; return try await session.data(for: request) }
    func refreshClock() async {
        guard !isBusy else { return }
        do { try await ensureClock(force: true); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }
    private func ensureClock(force: Bool = false) async throws {
        if !force, now != nil, ProcessInfo.processInfo.systemUptime - referenceUptime < 300 { return }
        var request = URLRequest(url: URL(string: "https://www.naver.com/?route_clock=" + UUID().uuidString)!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"; request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await send(request)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), http.url?.host == "www.naver.com",
              let header = http.value(forHTTPHeaderField: "Date"), let date = f.date(from: header), date.timeIntervalSince1970 * 1000 + 300_000 >= state.trustedMillis else { throw PlannerFailure.message("인터넷 시각을 확인하지 못했습니다. 사용량 초기화를 보류합니다.") }
        if let rawAge = http.value(forHTTPHeaderField: "Age") {
            guard let age = Double(rawAge), age.isFinite, age <= 5, age >= 0 else { throw PlannerFailure.message("이전 인터넷 시각 응답입니다. 다시 확인하세요.") }
        }
        var next = state; next.trustedMillis = max(next.trustedMillis, date.timeIntervalSince1970 * 1000); try commit(next)
        clock = Date(timeIntervalSince1970: next.trustedMillis / 1000); referenceUptime = ProcessInfo.processInfo.systemUptime
    }
    func query(mode: KakaoRouteMode, fixed: RouteEndpoint, others: [RouteEndpoint], priority: String, radius: Int, departure: Date?) async throws -> [KakaoDistanceRecord] {
        guard !isBusy else { throw PlannerFailure.message("다른 카카오 조회가 진행 중입니다.") }
        isBusy = true; defer { isBusy = false }
        try await DeviceShareHooks.prepareRequest(); try await ensureClock(); try Task.checkCancellation()
        guard let now, !state.settings.key.isEmpty, mode.isMap ? settings.mapFreeConfirmed : settings.naviFreeConfirmed else { throw PlannerFailure.message("카카오 키와 해당 API 사용 설정·무료 쿼터를 확인하세요.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        guard now.timeIntervalSince(calendar.startOfDay(for: now)) >= 300 else { throw PlannerFailure.message("일간 쿼터 초기화 확인을 위해 한국 시각 00:05 이후에 조회하세요.") }
        let request = try KakaoRouteAPI.request(mode: mode, origin: fixed, destinations: others, key: state.settings.key, priority: priority, radius: radius, departure: departure, now: now)
        var next = state; var reservations: [String] = []
        for (slot, period, limit) in [(mode.rawValue, Self.period(now), mode.dailyLimit), ("all", Self.period(now, monthly: true), 3_000_000)] {
            let id = usageID(slot, period: period); var entry = next.usage[id] ?? KakaoUsage()
            guard !entry.blocked, entry.used < limit else { throw PlannerFailure.message("카카오 무료 쿼터 한도에 도달했습니다.") }
            entry.used += 1; next.usage[id] = entry; reservations.append("kakao|" + account + "|" + period + "|" + slot)
        }
        try commit(next, reservations: reservations)
        let (data, response) = try await send(request); try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url?.host == request.url?.host else { throw PlannerFailure.message("카카오 응답 주소가 다릅니다.") }
        if http.statusCode == 429 {
            var blocked = state; let id = usageID(mode.rawValue, period: Self.period(now)); blocked.usage[id]?.blocked = true; try commit(blocked)
        }
        guard http.statusCode == 200 else { throw PlannerFailure.message("카카오 API 오류 (HTTP \(http.statusCode)). 키·사용 설정·쿼터를 확인하세요.") }
        let records = try KakaoRouteAPI.parse(data, mode: mode, origin: fixed, destinations: others, priority: priority, departure: departure, now: now)
        try saveResults(records); return records
    }
    func saveExternalResults(_ records: [KakaoDistanceRecord]) throws {
        guard !isBusy else { throw PlannerFailure.message("카카오 API 조회가 진행 중입니다.") }
        try saveResults(records)
    }
    private func saveResults(_ records: [KakaoDistanceRecord]) throws {
        guard !blockedRecovery else { throw APICredentialStorageError.notLoaded }
        guard let resultArchive else { throw DeviceShareError.unavailable }
        try resultArchive.append(records); results = try resultArchive.recent(); resultCount = try resultArchive.count
    }
    func exportCSV() async throws -> URL {
        let directory = resultURL.deletingLastPathComponent()
        let url = directory.appendingPathComponent("SiteDistances-" + UUID().uuidString + ".csv")
        try await Task.detached(priority: .utility) { try KakaoDistanceArchive(directory: directory).exportCSV(to: url) }.value
        return url
    }
    func sharingSnapshot() throws -> DeviceShareSnapshot {
        guard !blockedRecovery else { throw DeviceShareError.unavailable }
        var value = DeviceShareSnapshot()
        if !settings.key.isEmpty { value.values["setting/kakao"] = try DeviceShareCodec.encode(settings) }
        for (id, bucket) in state.usage {
            let parts = id.split(separator: "|").map(String.init); guard parts.count == 3 else { throw DeviceShareError.invalid }
            let limit = parts[2] == "all" ? 3_000_000 : KakaoRouteMode(rawValue: parts[2])?.dailyLimit ?? (parts[2] == "address" ? 100_000 : 1_000)
            value.usage.append(DeviceShareUsageObservation(domain: "kakao", account: parts[0], period: parts[1], slot: parts[2], used: bucket.used, limit: limit, blocked: bucket.blocked, trustedMillis: state.trustedMillis))
        }
        return value
    }
    func applySharing(_ replica: DeviceShareReplica) throws {
        var next = state
        if let settings = try replica.value("setting/kakao", as: KakaoSettings.self) { next.settings = settings }
        for entry in replica.usages("kakao") {
            let value = entry.observation; let id = value.account + "|" + value.period + "|" + value.slot
            var bucket = next.usage[id] ?? KakaoUsage(); bucket.used = max(bucket.used, entry.total); bucket.blocked = bucket.blocked || value.blocked
            next.usage[id] = bucket; next.trustedMillis = max(next.trustedMillis, value.trustedMillis)
        }
        let clockChanged = next.trustedMillis > state.trustedMillis
        if try DeviceShareCodec.encode(next) != DeviceShareCodec.encode(state) { try commit(next) }
        if clockChanged { clock = nil }
    }
}

private enum KakaoKeychain {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "kr.deliverytools.routeprobe.kakao", kSecAttrAccount as String: "state-v1"] }
    @MainActor static let archive = APICredentialArchive(readPrimary: { try readPrimary() }, writePrimary: { try writePrimary($0) },
        readProtected: { try APIProtectedStateFile(.kakao).read() }, writeProtected: { try APIProtectedStateFile(.kakao).write($0) },
        validate: { try KakaoRouteStore.validateSavedState($0) })
    static func readPrimary() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw PlannerFailure.message("카카오 키 보관함을 읽지 못했습니다. (\(status))") }
        return data
    }
    static func writePrimary(_ data: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PlannerFailure.message("카카오 키 보관함에 저장하지 못했습니다.") }
    }
}

extension KakaoRouteStore {
    func roadAddress(for source: HousingSource) async throws -> String? {
        guard !isBusy else { throw PlannerFailure.message("카카오 조회가 진행 중입니다.") }
        isBusy = true; defer { isBusy = false }
        try await DeviceShareHooks.prepareRequest(); try await ensureClock(); try Task.checkCancellation()
        guard let now, settings.mapFreeConfirmed, !settings.key.isEmpty else { throw PlannerFailure.message("카카오 주소 변환 설정을 확인하세요.") }
        let parcel = source.fields["parcelID"] ?? "", address = source.fields["jibunAddress"] ?? ""
        guard parcel.range(of: #"^\d{19}$"#, options: .regularExpression) != nil, !address.isEmpty else { return nil }
        var c = URLComponents(string: "https://dapi.kakao.com/v2/local/search/address.json")!
        c.queryItems = [URLQueryItem(name: "query", value: address), URLQueryItem(name: "analyze_type", value: "exact"), URLQueryItem(name: "size", value: "30")]
        var request = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("KakaoAK " + settings.key, forHTTPHeaderField: "Authorization")
        var next = state, reservations: [String] = []
        for (slot, period, limit) in [("address", Self.period(now), 100_000), ("all", Self.period(now, monthly: true), 3_000_000)] {
            let id = usageID(slot, period: period); var entry = next.usage[id] ?? KakaoUsage()
            guard !entry.blocked, entry.used < limit else { throw PlannerFailure.message("카카오 주소 변환 무료 한도입니다.") }
            entry.used += 1; next.usage[id] = entry; reservations.append("kakao|" + account + "|" + period + "|" + slot)
        }
        try commit(next, reservations: reservations)
        let (data, response) = try await send(request); try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "dapi.kakao.com", data.count <= 2_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let documents = object["documents"] as? [[String: Any]] else { throw PlannerFailure.message("카카오 주소 변환에 실패했습니다.") }
        var roads = Set<String>()
        for document in documents {
            guard let value = document["address"] as? [String: Any], let road = document["road_address"] as? [String: Any],
                  let bcode = value["b_code"] as? String, let main = Int(value["main_address_no"] as? String ?? ""),
                  let sub = Int(value["sub_address_no"] as? String ?? "0"), let mountain = value["mountain_yn"] as? String else { continue }
            let candidate = bcode + (mountain == "Y" ? "2" : "1") + String(format: "%04d%04d", main, sub)
            guard candidate == parcel, let text = road["address_name"] as? String, RealtyHousingClient.road(text) else { continue }; roads.insert(text)
        }
        return roads.count == 1 ? roads.first : nil
    }
}
