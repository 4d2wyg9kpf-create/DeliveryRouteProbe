import Foundation
import Combine
import CryptoKit
import Security

struct PublicDataQuota: Identifiable {
    var id: PublicDataService
    var used: Int
    var limit: Int
    var blocked: Bool
    var resetAt: Date?
    var remaining: Int { max(0, limit - used) }
}
private struct PublicQuotaAccount: Codable {
    var period: String
    var used: Int
    var blocked: Bool
}
private struct PublicSecureState: Codable {
    var version = 1
    var serviceKey = ""
    var approved: Set<String> = []
    var limits: [String: Int] = [:]
    var accounts: [String: PublicQuotaAccount] = [:]
    var lastTrustedMillis: Double = 0
}
struct PublicNearbyResult {
    var records: [PublicBusiness]
    var fetchedAt: Date
    var center: TMapCoordinate
    var radius: Int
    var sourceTotal: Int
    var skipped: Int
    var complete: Bool
    var issues: [String]
}
struct PublicSalesResult {
    var records: [PublicLicense]
    var fetchedAt: Date
    var from: String
    var through: String
    var complete: Bool
    var issues: [String]
    var services: [PublicDataService]
}
private struct PublicFetchedRows {
    var rows: [[String: Any]]
    var total: Int
    var month: String
    var complete: Bool
    var issues: [String]
}

private enum PublicDataKeychain {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "kr.deliverytools.routeprobe.public-data", kSecAttrAccount as String: "state-v1"] }
    @MainActor static let archive = APICredentialArchive(readPrimary: { try readPrimary() }, writePrimary: { try writePrimary($0) },
        readProtected: { try APIProtectedStateFile(.publicData).read() }, writeProtected: { try APIProtectedStateFile(.publicData).write($0) },
        validate: { try PublicDataStore.validateSavedState($0) })
    static func readPrimary() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw PublicDataFailure.message("공공데이터 키 보관함을 읽지 못했습니다. (\(status))") }
        return data
    }
    static func writePrimary(_ data: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PublicDataFailure.message("공공데이터 키 보관함에 저장하지 못했습니다.") }
    }
}
private final class PublicNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class PublicDataStore: ObservableObject {
    static let shared = PublicDataStore()
    @Published private(set) var hasKey = false
    @Published private(set) var approved: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var quotas: [PublicDataQuota] = []
    @Published private(set) var progress = ""
    @Published var errorMessage: String?
    private var state = PublicSecureState()
    private var blockedRecovery = false
    private var reference: (date: Date, uptime: TimeInterval)?
    private var clockUptime: TimeInterval?
    private var cooldownUntil: TimeInterval = 0
    private let writeState: (Data) throws -> Void
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let uptime: () -> TimeInterval
    private let delegate = PublicNetworkDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private convenience init() {
        self.init(read: { try PublicDataKeychain.archive.read() }, write: { try PublicDataKeychain.archive.write($0) }, transport: nil)
    }
    init(read: () throws -> Data?, write: @escaping (Data) throws -> Void,
         transport: ((URLRequest) async throws -> (Data, URLResponse))?, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.writeState = write; self.transport = transport; self.uptime = uptime
        do {
            if let data = try read() {
                try Self.validateSavedState(data); state = try JSONDecoder().decode(PublicSecureState.self, from: data)
            }
            publish()
        } catch { blockedRecovery = true; errorMessage = "공공데이터 키·사용량 기록 오류로 요청을 차단했습니다." }
    }
    static func validateSavedState(_ data: Data) throws {
        guard data.count <= 2_000_000 else { throw APICredentialStorageError.invalid }
        let value = try JSONDecoder().decode(PublicSecureState.self, from: data)
        let services = Set(PublicDataService.allCases.map(\.rawValue))
        guard value.version == 1, value.serviceKey.utf8.count <= 2_000, value.approved.isSubset(of: services),
              value.limits.keys.allSatisfy({ services.contains($0) }), value.limits.values.allSatisfy({ (1...10_000_000).contains($0) }),
              value.accounts.count <= 1_000, value.lastTrustedMillis.isFinite, value.lastTrustedMillis >= 0,
              value.accounts.values.allSatisfy({ (0...10_000_000).contains($0.used) && PublicDataParser.date($0.period) == $0.period }) else { throw APICredentialStorageError.invalid }
    }
    func limit(_ service: PublicDataService) -> Int { state.limits[service.rawValue] ?? 10_000 }
    @discardableResult
    func saveSettings(key: String, approved: Set<String>, limits: [String: Int]) -> Bool {
        guard !isBusy else { return false }
        do {
            var next = state
            let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !entered.isEmpty {
                let decoded = entered.contains("%") ? entered.removingPercentEncoding : entered
                guard let decoded, decoded.utf8.count <= 2_000, decoded.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                      decoded.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil else { throw PublicDataFailure.message("공공데이터 인증키 형식을 확인하세요.") }
                next.serviceKey = decoded
            }
            next.approved = approved; next.limits = limits
            try commit(next); errorMessage = nil; return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private var now: Date? {
        guard let reference else { return nil }
        return reference.date.addingTimeInterval(max(0, uptime() - reference.uptime))
    }
    private func accountKey(_ service: PublicDataService) -> String {
        service.rawValue + ":" + SHA256.hash(data: Data(state.serviceKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func period(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Seoul"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    private static func reset(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date))!.addingTimeInterval(300)
    }
    private func account(_ service: PublicDataService, at date: Date) -> PublicQuotaAccount {
        let current = Self.period(date), previous = state.accounts[accountKey(service)]
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let inGrace = date.timeIntervalSince(cal.startOfDay(for: date)) < 300
        if let previous, previous.period == current { return previous }
        if inGrace, let previous { return PublicQuotaAccount(period: previous.period, used: previous.used, blocked: true) }
        return PublicQuotaAccount(period: current, used: 0, blocked: inGrace)
    }
    private func publish() {
        hasKey = !state.serviceKey.isEmpty; approved = state.approved
        quotas = PublicDataService.allCases.map { service in
            let account = now.map { self.account(service, at: $0) } ?? state.accounts[accountKey(service)]
            return PublicDataQuota(id: service, used: account?.used ?? 0, limit: limit(service), blocked: blockedRecovery || account?.blocked == true || (account?.used ?? 0) >= limit(service), resetAt: now.map {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
                let morning = cal.startOfDay(for: $0).addingTimeInterval(300)
                return $0 < morning ? morning : Self.reset($0)
            })
        }
    }
    private func commit(_ next: PublicSecureState) throws {
        guard !blockedRecovery else { throw PublicDataFailure.message("보관함 오류를 해결한 뒤 다시 시도하세요.") }
        let data = try JSONEncoder().encode(next); try Self.validateSavedState(data); try writeState(data)
        state = next; publish()
    }
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let transport { return try await transport(request) }
        do { return try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PublicDataFailure.message("공공데이터 서버에 연결하지 못했습니다. 네트워크를 확인하세요.") }
    }
    private func clockDate(_ response: HTTPURLResponse, request: URLRequest, started: TimeInterval) throws -> Date {
        // The data gateway root is not a clock endpoint: it can return no Date.
        // These credential-free HTTPS requests never carry or consume a ServiceKey.
        guard response.url == request.url, response.url?.scheme == "https",
              ["www.naver.com", "www.data.go.kr"].contains(response.url?.host ?? ""),
              (200..<500).contains(response.statusCode), !(300..<400).contains(response.statusCode),
              uptime() - started >= 0, uptime() - started <= 10,
              let age = Double(response.value(forHTTPHeaderField: "Age") ?? "0"), age.isFinite, (0...30).contains(age),
              let text = response.value(forHTTPHeaderField: "Date") else { throw PublicDataFailure.message("인터넷 기준 시각 응답을 확인하지 못했습니다.") }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = f.date(from: text), (1_577_836_800...4_102_444_800).contains(date.timeIntervalSince1970),
              date.timeIntervalSince1970 * 1_000 + 2_000 >= state.lastTrustedMillis else { throw PublicDataFailure.message("기준 시각이 이전 기록보다 과거여서 요청을 차단했습니다.") }
        return date
    }
    private func ensureClock(force: Bool = false) async throws {
        if !force, now != nil, let clockUptime, uptime() - clockUptime < 300 { return }
        for host in ["www.naver.com", "www.data.go.kr"] {
            var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = "/"
            components.queryItems = [URLQueryItem(name: "delivery_clock", value: UUID().uuidString)]
            for method in ["HEAD", "GET"] {
                var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
                request.httpMethod = method
                request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
                let started = uptime()
                let date: Date
                do {
                    try Task.checkCancellation()
                    let (_, response) = try await send(request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else { continue }
                    date = try clockDate(http, request: request, started: started)
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
                var next = state; next.lastTrustedMillis = max(next.lastTrustedMillis, date.timeIntervalSince1970 * 1_000)
                // A storage error must stop here; it is not a reason to retry a network request.
                try commit(next)
                reference = (Date(timeIntervalSince1970: next.lastTrustedMillis / 1_000), uptime())
                clockUptime = uptime(); publish(); return
            }
        }
        throw PublicDataFailure.message("인터넷 기준 시각을 확인하지 못해 조회를 보류했습니다. 네트워크를 확인하고 다시 조회해 주세요. 인증키와 사용량 기록은 유지됩니다.")
    }
    func refreshClock() async {
        guard !isBusy, !blockedRecovery else { return }
        isBusy = true; defer { isBusy = false }
        do { try await ensureClock(force: true); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }
    private func reserve(_ service: PublicDataService) throws {
        guard hasKey, approved.contains(service.rawValue), let now, !blockedRecovery else { throw PublicDataFailure.message("인증키를 저장하고 '\(service.title)' 활용승인을 확인하세요.") }
        guard uptime() >= cooldownUntil else { throw PublicDataFailure.message("초당 요청 제한으로 잠시 기다려 주세요.") }
        var entry = account(service, at: now)
        guard !entry.blocked, entry.used < limit(service) else { throw PublicDataFailure.message("'\(service.title)' 한도 소진·초기화 대기로 요청을 차단했습니다.") }
        entry.used += 1
        var next = state; next.accounts[accountKey(service)] = entry
        // Persist the request count before any billable request leaves.
        try commit(next)
    }
    private func page(_ service: PublicDataService, parameters: [String: String], page: Int) async throws -> PublicDataPage {
        try Task.checkCancellation()
        var url = URLComponents(); url.scheme = "https"; url.host = "apis.data.go.kr"; url.path = service.path
        var parameters = parameters
        parameters[service == .stores ? "ServiceKey" : "serviceKey"] = state.serviceKey
        parameters["pageNo"] = String(page); parameters["numOfRows"] = "100"
        parameters[service == .stores ? "type" : "returnType"] = "json"
        url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let target = url.url else { throw PublicDataFailure.message("공공데이터 조회 주소를 만들지 못했습니다.") }
        try reserve(service)
        let (data, response) = try await send(URLRequest(url: target))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == "apis.data.go.kr",
              !(300..<400).contains(http.statusCode) else { throw PublicDataFailure.message("공공데이터 응답 출처를 확인하지 못했습니다.") }
        // Keep the independently verified clock. Missing or cached gateway Date
        // headers must not discard an otherwise valid, already counted response.
        do {
            let result = try PublicDataParser.page(data, expectedPage: page, expectedSize: 100)
            guard (200..<300).contains(http.statusCode) else { throw PublicDataFailure.message("공공데이터 HTTP 오류 \(http.statusCode)") }
            return result
        } catch PublicDataFailure.provider(let code) {
            if ["22", "-10"].contains(code), let now {
                var next = state; var entry = account(service, at: now); entry.blocked = true
                next.accounts[accountKey(service)] = entry; try commit(next)
            } else if code == "23" { cooldownUntil = uptime() + 10 }
            throw PublicDataFailure.provider(code)
        }
    }
    private func allRows(_ service: PublicDataService, parameters: [String: String]) async throws -> PublicFetchedRows {
        var rows: [[String: Any]] = [], total: Int?, month = ""
        var identifiers = Set<String>()
        for number in 1...100 {
            do {
                let part = try await page(service, parameters: parameters, page: number)
                if let total, total != part.total { throw PublicDataFailure.message("조회 중 전체 건수가 바뀌었습니다. 다시 조회하세요.") }
                total = part.total; if !part.referenceMonth.isEmpty { month = part.referenceMonth }
                for row in part.rows {
                    let identifier = PublicDataParser.string(row, service == .stores ? "bizesId" : "MNG_NO")
                    if !identifier.isEmpty, !identifiers.insert(identifier).inserted { throw PublicDataFailure.message("응답 페이지에 중복 업체가 있습니다. 전체 목록을 확인하려면 다시 조회하세요.") }
                }
                rows.append(contentsOf: part.rows)
                guard rows.count <= part.total else { throw PublicDataFailure.message("응답 건수가 전체 개수보다 많습니다.") }
                progress = "\(service.title) · \(rows.count.formatted())/\(part.total.formatted())건"
                if rows.count == part.total { return PublicFetchedRows(rows: rows, total: part.total, month: month, complete: true, issues: []) }
                // Permit an async cancellation between pages, without automatic
                // retries that could burn quota or exceed per-second limits.
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if rows.isEmpty { throw error }
                return PublicFetchedRows(rows: rows, total: total ?? rows.count, month: month, complete: false, issues: [error.localizedDescription])
            }
        }
        return PublicFetchedRows(rows: rows, total: total ?? rows.count, month: month, complete: false, issues: ["10,000건 조회 범위에 도달했습니다. 반경·기간을 줄여 다시 조회하세요."])
    }
    func nearby(center: TMapCoordinate, radius: Int) async throws -> PublicNearbyResult {
        guard !isBusy else { throw PublicDataFailure.message("다른 공공데이터 조회가 진행 중입니다.") }
        guard !blockedRecovery else { throw PublicDataFailure.message(errorMessage ?? "공공데이터 보관함 오류로 조회를 차단했습니다.") }
        guard radius >= 1, radius <= 2_000, center.latitude.isFinite, center.longitude.isFinite,
              (32...40).contains(center.latitude), (124...132).contains(center.longitude) else { throw PublicDataFailure.message("평가대상지 좌표와 반경 1~2,000m를 확인하세요.") }
        guard hasKey, approved.contains(PublicDataService.stores.rawValue) else { throw PublicDataFailure.message("인증키를 저장하고 '주변 업체' 활용승인을 확인하세요.") }
        isBusy = true; errorMessage = nil; defer { isBusy = false }
        try await ensureClock()
        let rows = try await allRows(.stores, parameters: ["radius": String(radius), "cx": String(center.longitude), "cy": String(center.latitude)])
        var businesses: [String: PublicBusiness] = [:], skipped = 0
        for row in rows.rows {
            if let entry = PublicDataParser.business(row, center: center, radius: radius, month: rows.month) { businesses[entry.id] = entry }
            else { skipped += 1 }
        }
        return PublicNearbyResult(records: businesses.values.sorted { $0.distanceMeters < $1.distanceMeters }, fetchedAt: now!, center: center,
            radius: radius, sourceTotal: rows.total, skipped: skipped, complete: rows.complete, issues: rows.issues)
    }
    func newDaejeonLicenses(from: String, through: String, services: [PublicDataService]) async throws -> PublicSalesResult {
        guard !isBusy else { throw PublicDataFailure.message("다른 공공데이터 조회가 진행 중입니다.") }
        guard !blockedRecovery else { throw PublicDataFailure.message(errorMessage ?? "공공데이터 보관함 오류로 조회를 차단했습니다.") }
        guard PublicDataParser.date(from) == from, PublicDataParser.date(through) == through, from <= through,
              !services.isEmpty, services.allSatisfy({ $0 != .stores }), Set(services).count == services.count else { throw PublicDataFailure.message("인허가일자 범위와 업종을 확인하세요.") }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "Asia/Seoul"); format.dateFormat = "yyyy-MM-dd"
        guard let end = format.date(from: through), let start = format.date(from: from), end.timeIntervalSince(start) <= 366 * 86_400 else { throw PublicDataFailure.message("한 번에 최대 1년의 인허가일자를 조회합니다.") }
        guard hasKey, services.contains(where: { approved.contains($0.rawValue) }) else { throw PublicDataFailure.message("공공데이터 인증키를 저장하고 선택한 인허가 API의 활용승인을 확인하세요.") }
        isBusy = true; errorMessage = nil; defer { isBusy = false }
        try await ensureClock()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        format.dateFormat = "yyyyMMdd"; let exclusive = format.string(from: cal.date(byAdding: .day, value: 1, to: end)!)
        var result: [String: PublicLicense] = [:], issues: [String] = [], complete = true
        for service in services {
            guard approved.contains(service.rawValue) else { complete = false; issues.append("\(service.title): 활용승인 확인 필요"); continue }
            for authority in PublicDataParser.daejeonAuthorities {
                try Task.checkCancellation()
                do {
                    let fetched = try await allRows(service, parameters: ["cond[LCPMT_YMD::GTE]": from.replacingOccurrences(of: "-", with: ""),
                        "cond[LCPMT_YMD::LT]": exclusive, "cond[SALS_STTS_CD::EQ]": "01", "cond[OPN_ATMY_GRP_CD::EQ]": authority])
                    if !fetched.complete { complete = false; issues.append(contentsOf: fetched.issues.map { "\(service.title): \($0)" }) }
                    for row in fetched.rows {
                        if let entry = PublicDataParser.license(row, service: service, from: from, through: through) {
                            if let previous = result[entry.id], previous.updatedAt > entry.updatedAt { continue }
                            result[entry.id] = entry
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { complete = false; issues.append("\(service.title) · 자치단체 \(authority): \(error.localizedDescription)"); break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return PublicSalesResult(records: result.values.sorted { $0.permissionDate == $1.permissionDate ? $0.name < $1.name : $0.permissionDate > $1.permissionDate },
            fetchedAt: now!, from: from, through: through, complete: complete, issues: issues, services: services)
    }
}
