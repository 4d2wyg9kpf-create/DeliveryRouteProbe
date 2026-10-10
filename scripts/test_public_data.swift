import Foundation

// Type-only dependency; the shipped public API store/parser/archive compile
// unchanged. All responses below are synthetic; no real key/network is used.
struct TMapCoordinate: Codable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
private enum CheckFailure: Error { case failed(String) }
private func require(_ condition: Bool, _ label: String) throws { if !condition { throw CheckFailure.failed(label) } }
private func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
private let center = TMapCoordinate(longitude: 127.4, latitude: 36.3)
private func business(_ id: String, longitude: String = "127.4", latitude: String = "36.3") -> [String: Any] {
    ["bizesId": id, "bizesNm": "가상 업체 \(id)", "brchNm": "가상지점", "rdnmAdr": "대전광역시 중구 가상로 1", "lon": longitude, "lat": latitude,
     "indsSclsNm": "가상 음식점", "indsLclsCd": "I2", "stdrYm": "202609"]
}
private func license(_ id: String = "fixture-permit", date: String = "20261010", authority: String = "3640000", state: String = "01", detail: String = "영업") -> [String: Any] {
    ["MNG_NO": id, "BPLC_NM": "가상 신규 업체", "LCPMT_YMD": date, "OPN_ATMY_GRP_CD": authority, "ROAD_NM_ADDR": "", "LOTNO_ADDR": "대전광역시 동구 가상동 1",
     "SALS_STTS_CD": state, "SALS_STTS_NM": state == "01" ? "영업/정상" : "폐업", "DTL_SALS_STTS_NM": detail, "CLSBIZ_YMD": "", "DAT_UPDT_PNT": "20261010010000",
     "CRD_INFO_X": "236000", "CRD_INFO_Y": "316000", "TELNO": ""]
}
private func page(rows: [[String: Any]], total: Int, number: Int = 1, code: String = "00", nested: Bool = true) throws -> Data {
    let body: [String: Any] = ["pageNo": number, "numOfRows": 100, "totalCount": total, "items": ["item": rows], "stdrYm": "202609"]
    let response: [String: Any] = ["header": ["resultCode": code, "resultMsg": "synthetic"], "body": body]
    let payload: [String: Any] = nested ? ["response": response] : response
    return try bytes(payload)
}

@MainActor private final class Fixture {
    var data: Data?
    var requests: [URLRequest] = []
    var writeFails = false
    var badClock = false
    var redirect = false
    var millis: TimeInterval = 1_791_601_200 // overwritten by ISO date below
    var ticks: TimeInterval = 10
    var responder: ((URLRequest) throws -> Data)?
    var heads = 0
    var gets: Int { requests.filter { $0.httpMethod != "HEAD" }.count }
    init() {
        millis = ISO8601DateFormatter().date(from: "2026-10-10T03:00:00Z")!.timeIntervalSince1970
    }
    func store() -> PublicDataStore {
        PublicDataStore(read: { self.data }, write: { if self.writeFails { throw CheckFailure.failed("synthetic storage failure") }; self.data = $0 },
            transport: { request in
                self.requests.append(request)
                let isHead = request.httpMethod == "HEAD"
                if isHead { self.heads += 1 }
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                let header = self.badClock ? [:] : ["Date": f.string(from: Date(timeIntervalSince1970: self.millis))]
                let response = HTTPURLResponse(url: self.redirect ? URL(string: "https://example.invalid/")! : request.url!, statusCode: self.redirect ? 302 : 200, httpVersion: "HTTP/1.1", headerFields: header)!
                if isHead { return (Data(), response) }
                return (try self.responder?(request) ?? page(rows: [business("one")], total: 1, nested: false), response)
            }, uptime: { self.ticks })
    }
    func ready(_ store: PublicDataStore, limit: Int = 10_000, services: Set<String> = Set(PublicDataService.allCases.map(\.rawValue))) throws {
        try require(store.saveSettings(key: "fixture-key", approved: services, limits: Dictionary(uniqueKeysWithValues: PublicDataService.allCases.map { ($0.rawValue, limit) })), "settings save")
    }
}

@main struct PublicDataNativeChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ label: String, _ action: () throws -> Void) throws { try action(); passed += 1; print("PASS \(label)") }
        func asyncCheck(_ label: String, _ action: () async throws -> Void) async throws { try await action(); passed += 1; print("PASS \(label)") }
        try check("nested JSON, numeric metadata, empty list") {
            let result = try PublicDataParser.page(page(rows: [], total: 0), expectedPage: 1, expectedSize: 100)
            try require(result.rows.isEmpty && result.total == 0, "empty response")
        }
        try check("wrong response page rejected") {
            do { _ = try PublicDataParser.page(page(rows: [business("x")], total: 1, number: 2), expectedPage: 1, expectedSize: 100); throw CheckFailure.failed("accepted wrong page") } catch is PublicDataFailure {}
        }
        try check("malformed success is not an empty result") {
            do { _ = try PublicDataParser.page(bytes(["resultCode": "00"]), expectedPage: 1, expectedSize: 100); throw CheckFailure.failed("accepted missing body") } catch is PublicDataFailure {}
        }
        try check("short page or extra rows cannot be presented as a complete list") {
            for fixture in [try page(rows: [business("one")], total: 200), try page(rows: [business("one"), business("two")], total: 1)] {
                do { _ = try PublicDataParser.page(fixture, expectedPage: 1, expectedSize: 100); throw CheckFailure.failed("accepted inconsistent count") } catch is PublicDataFailure {}
            }
        }
        try check("XML gateway quota error decoded without raw response") {
            do { _ = try PublicDataParser.page(Data("<OpenAPI_ServiceResponse><returnReasonCode>22</returnReasonCode></OpenAPI_ServiceResponse>".utf8), expectedPage: 1, expectedSize: 100); throw CheckFailure.failed("accepted error") }
            catch PublicDataFailure.provider(let code) { try require(code == "22", "code") }
        }
        try check("WGS84 coordinates accepted, EPSG5174 rejected") {
            try require(PublicDataParser.business(business("x"), center: center, radius: 500, month: "") != nil, "valid coordinates")
            try require(PublicDataParser.business(business("y", longitude: "236000", latitude: "316000"), center: center, radius: 500, month: "") == nil, "projected coordinates")
        }
        try check("actual straight line radius filter") {
            try require(PublicDataParser.business(business("near", longitude: "127.4001"), center: center, radius: 500, month: "") != nil, "nearby")
            try require(PublicDataParser.business(business("far", longitude: "127.42"), center: center, radius: 500, month: "") == nil, "far")
        }
        try check("permit date, not modification date, drives new license list") {
            try require(PublicDataParser.license(license(date: "20260101"), service: .restaurants, from: "2026-10-01", through: "2026-10-10") == nil, "old permit modified today")
            try require(PublicDataParser.license(license(), service: .restaurants, from: "2026-10-01", through: "2026-10-10")?.permissionDate == "2026-10-10", "new permit")
        }
        try check("closed or suspended licenses excluded even with normal primary code") {
            for value in [license(state: "03"), license(detail: "폐업"), license(detail: "휴업"), license(detail: "영업정지")] {
                try require(PublicDataParser.license(value, service: .cafes, from: "2026-10-01", through: "2026-10-10") == nil, "status filter")
            }
        }
        try check("Daejeon authority and address checked, empty road uses lot address") {
            try require(PublicDataParser.license(license(), service: .canteens, from: "2026-10-01", through: "2026-10-10")?.address == "대전광역시 동구 가상동 1", "lot fallback")
            try require(PublicDataParser.license(license(authority: "4111000"), service: .canteens, from: "2026-10-01", through: "2026-10-10") == nil, "other authority")
            var contradictory = license(); contradictory["ROAD_NM_ADDR"] = "경기도 수원시 대전로 1"
            try require(PublicDataParser.license(contradictory, service: .canteens, from: "2026-10-01", through: "2026-10-10") == nil, "name substring")
        }
        try check("invalid calendar dates rejected") {
            try require(PublicDataParser.date("20260230") == nil && PublicDataParser.date("2026-02-28") == "2026-02-28", "date validation")
        }
        try await asyncCheck("encoded key normalized once and sent to HTTPS allowlist") {
            let f = Fixture(), store = f.store()
            try require(store.saveSettings(key: "fixture%2Bkey%2F%3D", approved: ["stores"], limits: [:]), "encoded key")
            _ = try await store.nearby(center: center, radius: 500)
            let url = f.requests.last!.url!, params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            try require(url.host == "apis.data.go.kr" && url.scheme == "https", "destination")
            try require(params.first { $0.name == "ServiceKey" }?.value == "fixture+key/=", "key encoding")
            try require(params.first { $0.name == "radius" }?.value == "500" && params.first { $0.name == "cx" }?.value == "127.4", "radius parameters")
        }
        try await asyncCheck("last allowed request, then quota gate before dispatch") {
            let f = Fixture(), store = f.store(); try f.ready(store, limit: 1)
            _ = try await store.nearby(center: center, radius: 500)
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("quota bypass") } catch is PublicDataFailure {}
            try require(f.gets == 1 && store.quotas.first { $0.id == .stores }?.remaining == 0, "request boundary")
        }
        try await asyncCheck("unapproved service is not dispatched") {
            let f = Fixture(), store = f.store(); try f.ready(store, services: ["cafes"])
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("approval bypass") } catch is PublicDataFailure {}
            try require(f.gets == 0, "no charge")
        }
        try await asyncCheck("storage failure gates requests") {
            let f = Fixture(), store = f.store(); try f.ready(store); f.writeFails = true
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("storage bypass") } catch {}
            try require(f.gets == 0, "no charge")
        }
        try await asyncCheck("missing trusted clock gates requests") {
            let f = Fixture(), store = f.store(); try f.ready(store); f.badClock = true
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("clock bypass") } catch is PublicDataFailure {}
            try require(f.gets == 0, "no charge")
        }
        try await asyncCheck("server clock rollback cannot reset the exhausted daily quota") {
            let f = Fixture(), initial = f.store(); try f.ready(initial, limit: 1)
            _ = try await initial.nearby(center: center, radius: 500)
            f.millis -= 86_400
            let restored = f.store()
            do { _ = try await restored.nearby(center: center, radius: 500); throw CheckFailure.failed("rollback reset") } catch is PublicDataFailure {}
            try require(f.gets == 1 && restored.quotas.first { $0.id == .stores }?.used == 1, "preserved exhausted count")
        }
        try await asyncCheck("KST midnight waits five minutes and then resumes on the new day") {
            let f = Fixture(), store = f.store(); try f.ready(store, limit: 1)
            f.millis = ISO8601DateFormatter().date(from: "2026-10-10T14:59:00Z")!.timeIntervalSince1970
            _ = try await store.nearby(center: center, radius: 500)
            f.millis = ISO8601DateFormatter().date(from: "2026-10-10T15:02:00Z")!.timeIntervalSince1970
            await store.refreshClock()
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("midnight grace bypass") } catch is PublicDataFailure {}
            try require(f.gets == 1, "grace gate")
            f.millis = ISO8601DateFormatter().date(from: "2026-10-10T15:05:00Z")!.timeIntervalSince1970
            await store.refreshClock()
            _ = try await store.nearby(center: center, radius: 500)
            try require(f.gets == 2 && store.quotas.first { $0.id == .stores }?.used == 1, "new day resumed with one counted request")
        }
        try await asyncCheck("failed network request remains counted after recreation") {
            let f = Fixture(), initial = f.store(); try f.ready(initial, limit: 1)
            f.responder = { _ in throw CheckFailure.failed("synthetic network failure") }
            do { _ = try await initial.nearby(center: center, radius: 500); throw CheckFailure.failed("accepted failure") } catch {}
            let restored = f.store(); f.responder = nil
            do { _ = try await restored.nearby(center: center, radius: 500); throw CheckFailure.failed("failure count reset") } catch is PublicDataFailure {}
            try require(f.gets == 1 && restored.quotas.first { $0.id == .stores }?.used == 1, "failed request persisted")
        }
        try await asyncCheck("redirected clock does not cause an API request") {
            let f = Fixture(), store = f.store(); try f.ready(store); f.redirect = true
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("redirect accepted") } catch is PublicDataFailure {}
            try require(f.gets == 0, "no charged redirect")
        }
        try await asyncCheck("one exhausted service does not consume another service allowance") {
            let f = Fixture(), store = f.store(); try f.ready(store, limit: 6)
            for _ in 0..<6 { _ = try await store.nearby(center: center, radius: 500) }
            f.responder = { request in
                let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let authority = params.first { $0.name == "cond[OPN_ATMY_GRP_CD::EQ]" }!.value!
                return try page(rows: [license(authority, authority: authority)], total: 1)
            }
            let result = try await store.newDaejeonLicenses(from: "2026-10-01", through: "2026-10-10", services: [.restaurants])
            try require(result.complete && result.records.count == 6 && f.gets == 12, "service independent usage")
        }
        try await asyncCheck("key and quota survive store recreation and blank setting") {
            let f = Fixture(), initial = f.store(); try f.ready(initial, limit: 1); _ = try await initial.nearby(center: center, radius: 500)
            let restored = f.store(); try require(restored.hasKey, "restored key")
            try require(restored.saveSettings(key: "", approved: restored.approved, limits: ["stores": 1]), "blank setting")
            do { _ = try await restored.nearby(center: center, radius: 500); throw CheckFailure.failed("quota reset after recreation") } catch is PublicDataFailure {}
            try require(f.gets == 1, "persisted quota")
        }
        try await asyncCheck("all radius pages gathered with count verification") {
            let f = Fixture(), store = f.store(); try f.ready(store)
            f.responder = { request in
                let number = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pageNo" }!.value!)!
                let start = (number - 1) * 100, count = min(100, 250 - start)
                return try page(rows: (start..<(start + count)).map { business(String($0)) }, total: 250, number: number, nested: false)
            }
            let result = try await store.nearby(center: center, radius: 500)
            try require(f.gets == 3 && result.complete && result.records.count == 250, "pagination")
        }
        try await asyncCheck("page error returns explicit partial list and persists server quota block") {
            let f = Fixture(), store = f.store(); try f.ready(store)
            f.responder = { request in
                let number = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pageNo" }!.value!)!
                return number == 1 ? try page(rows: (0..<100).map { business(String($0)) }, total: 200, nested: false) : Data("<returnReasonCode>22</returnReasonCode>".utf8)
            }
            let result = try await store.nearby(center: center, radius: 500)
            try require(!result.complete && result.records.count == 100 && !result.issues.isEmpty, "partial list")
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("server quota bypass") } catch is PublicDataFailure {}
            try require(f.gets == 2, "block before next dispatch")
        }
        try await asyncCheck("overlapping response pages are incomplete") {
            let f = Fixture(), store = f.store(); try f.ready(store)
            f.responder = { request in
                let number = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pageNo" }!.value!)!
                return try page(rows: (0..<100).map { business(String($0)) }, total: 200, number: number, nested: false)
            }
            let result = try await store.nearby(center: center, radius: 500)
            try require(!result.complete && result.records.count == 100 && !result.issues.isEmpty, "duplicate page")
        }
        try await asyncCheck("invalid radius rejected without clock or data dispatch") {
            let f = Fixture(), store = f.store(); try f.ready(store)
            do { _ = try await store.nearby(center: center, radius: 2001); throw CheckFailure.failed("radius bypass") } catch is PublicDataFailure {}
            try require(f.requests.isEmpty, "validation before network")
        }
        try await asyncCheck("five services, six Daejeon authorities, inclusive end date and live status") {
            let f = Fixture(), store = f.store(); try f.ready(store)
            f.responder = { request in
                let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                try require(params.first { $0.name == "cond[LCPMT_YMD::GTE]" }?.value == "20261001", "permit start")
                try require(params.first { $0.name == "cond[LCPMT_YMD::LT]" }?.value == "20261011", "exclusive next day")
                try require(params.first { $0.name == "cond[SALS_STTS_CD::EQ]" }?.value == "01", "active filter")
                let authority = params.first { $0.name == "cond[OPN_ATMY_GRP_CD::EQ]" }!.value!
                let entries = authority == "3640000" ? [license()] : []
                return try page(rows: entries, total: entries.count)
            }
            let result = try await store.newDaejeonLicenses(from: "2026-10-01", through: "2026-10-10", services: PublicDataService.licenses)
            try require(result.complete && result.records.count == 5 && f.gets == 30, "services and jurisdictions")
        }
        try await asyncCheck("unapproved license category reports omission instead of complete zero") {
            let f = Fixture(), store = f.store(); try f.ready(store, services: [])
            let result = try await store.newDaejeonLicenses(from: "2026-10-01", through: "2026-10-10", services: [.restaurants])
            try require(!result.complete && !result.issues.isEmpty && f.gets == 0, "explicit omission")
        }
        try await asyncCheck("corrupt persisted state gates requests") {
            let f = Fixture(); f.data = Data("broken".utf8); let store = f.store()
            do { _ = try await store.nearby(center: center, radius: 500); throw CheckFailure.failed("corruption bypass") } catch {}
            try require(f.gets == 0 && store.errorMessage != nil, "no data dispatch")
        }
        print("Public data native checks: \(passed)/\(passed) passed")
    }
}
