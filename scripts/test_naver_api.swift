// Test-only model dependencies. The shipped store, models and JS bridges compile below.
import Foundation

struct TMapCoordinate: Codable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
struct MapRoutePoint: Codable { var token: String; var name: String }
struct TestStop: Codable { var id = ""; var naverPlace: NaverPlaceCapture? }
struct DeliveryPlan: Codable { var naverOrigin: NaverPlaceCapture?; var visits: [TestStop] = []; var destination: TestStop? }
enum PlannerFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
enum TMapBridge {
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
}
private func require(_ value: Bool, _ message: String) throws { if !value { throw PlannerFailure.message(message) } }

@MainActor
private final class Fixture {
    var data: Data
    var writeFails = false
    var corruptRead = false
    var getCount = 0
    var headCount = 0
    var status = 200
    var serverErrorCode: String?
    var serverErrorMessage = "fixture error"
    var headStatus = 200
    var cancelGET = false
    var delayGET = false
    var getRelease: CheckedContinuation<Void, Never>?
    var mismatchedAddress = false
    var nestedError = false
    var serverErrorDetails = ""
    var decimalSearchCoordinate = false
    var requests: [URLRequest] = []
    init(free: Bool = true, search: Bool = true, maps: Bool = true, provider: NaverSearchProvider? = .hub, hubFree: Bool = true) throws {
        var json: [String: Any] = ["version": 1, "searchID": search ? "fixture-client" : "", "searchSecret": search ? "fixture-secret" : "", "searchFreeConfirmed": hubFree, "mapsID": maps ? "fixture-maps" : "", "mapsSecret": maps ? "fixture-map-secret" : "", "mapsFreeConfirmed": free, "ledger": ["version": 1, "accounts": [:]]]
        if let provider { json["searchProvider"] = provider.rawValue }
        data = try JSONSerialization.data(withJSONObject: json)
    }
    func store() -> NaverAPIStore {
        NaverAPIStore(read: { self.corruptRead ? Data("broken".utf8) : self.data }, write: {
            if self.writeFails { throw PlannerFailure.message("fixture storage failure") }; self.data = $0
        }, transport: { request in try await self.respond(request) })
    }
    func used(_ provider: String) throws -> Int {
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ledger = json["ledger"] as! [String: Any], accounts = ledger["accounts"] as! [String: [String: Any]]
        let prefix = provider == "maps" ? "maps-" : provider == "searchMonth" ? "hub-month:" : (json["searchProvider"] as? String == "hub" ? "hub:" : "search:")
        return accounts.first(where: { $0.key.hasPrefix(prefix) })?.value["used"] as? Int ?? 0
    }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let head = request.httpMethod == "HEAD"
        if head { headCount += 1 } else {
            getCount += 1
            let provider = request.url!.host == "maps.apigw.ntruss.com" ? "maps" : "search"
            try require(try used(provider) > 0, "request dispatched before persisted reservation")
            if request.url!.host == "naverapihub.apigw.ntruss.com" { try require(try used("searchMonth") > 0, "monthly reservation not persisted before HUB request") }
            if cancelGET { throw CancellationError() }
            if delayGET && getCount == 1 { await withCheckedContinuation { getRelease = $0 } }
        }
        let address = mismatchedAddress ? "대전 중구 유천로 350" : "대전광역시 중구 유천로 35"
        let json: [String: Any]
        if head { json = [:] }
        else if status != 200 {
            let code = serverErrorCode ?? (status == 429 ? "429" : "SE01")
            json = nestedError ? ["error": ["errorCode": code, "message": serverErrorMessage, "details": serverErrorDetails]] : ["errorCode": code, "errorMessage": serverErrorMessage]
        }
        else if request.url!.host != "maps.apigw.ntruss.com" {
            json = ["items": [["title": "<b>가상</b> 거래처", "roadAddress": address, "address": "대전 중구 유천동 100", "category": "배송", "mapx": decimalSearchCoordinate ? "127.398" : "1273980000", "mapy": decimalSearchCoordinate ? "36.316" : "363160000"]]]
        } else {
            json = ["status": "OK", "addresses": [["roadAddress": address, "jibunAddress": "대전 중구 유천동 100", "x": "127.398", "y": "36.316"]]]
        }
        return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: head ? headStatus : status, httpVersion: "HTTP/1.1", headerFields: ["Date": "Fri, 09 Oct 2026 14:50:00 GMT", "Age": "0", "Retry-After": "1"])!)
    }
}

@main
struct NaverAPINativeTests {
    @MainActor static func main() async {
        var checks: [[String: Any]] = []
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); checks.append(["name": name, "passed": true]) }
            catch { checks.append(["name": name, "passed": false, "error": error.localizedDescription]) }
        }
        func rejects(_ body: () async throws -> Void) async throws {
            do { try await body() } catch { return }; throw PlannerFailure.message("expected rejection")
        }
        await test("HUB local endpoint, Cloud headers and atomic daily/monthly persist-before-dispatch") {
            let f = try Fixture(), s = f.store(), r = try await s.search("가상 거래처 대전")
            try require(r.count == 1 && r[0].capture.coordinate?.longitude == 127.398, "bad coordinate")
            let q = f.requests.last!
            try require(q.url?.host == "naverapihub.apigw.ntruss.com" && q.url?.path == "/search/v1/local", "wrong HUB endpoint")
            let query = URLComponents(url: q.url!, resolvingAgainstBaseURL: false)!.queryItems!
            try require(query.contains(where: { $0.name == "format" && $0.value == "json" }) && query.contains(where: { $0.name == "display" && $0.value == "5" }), "wrong HUB query")
            try require(q.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY-ID") == "fixture-client" && q.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY") == "fixture-secret", "wrong Cloud headers")
            try require(q.value(forHTTPHeaderField: "X-Naver-Client-Id") == nil && q.value(forHTTPHeaderField: "Content-Type") == nil, "legacy/POST header leaked to HUB GET")
            try require(r[0].capture.geocodeProvider == "NAVER API HUB", "HUB proof not recorded")
            try require(try f.used("search") == 1 && f.getCount == 1 && (try f.used("searchMonth")) == 1, "wrong reservation")
        }
        await test("25,000th search allowed, 25,001st never dispatched") {
            let f = try Fixture(), s = f.store(); await s.raiseUsage(provider: "search", used: 24999)
            _ = try await s.search("가상 거래처")
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 1 && s.quotas["search"]?.remaining == 0, "search free cap exceeded")
        }
        await test("new Maps official host and separate credentials") {
            let f = try Fixture(), s = f.store(), r = try await s.address("대전 중구 유천로 35", name: "가상 거래처")
            try require(r.coordinate?.latitude == 36.316, "wrong geocode coordinate")
            let q = f.requests.last!
            try require(q.url?.host == "maps.apigw.ntruss.com" && q.url?.path == "/map-geocode/v2/geocode", "old/paid Maps endpoint")
            try require(q.value(forHTTPHeaderField: "x-ncp-apigw-api-key-id") == "fixture-maps" && q.value(forHTTPHeaderField: "x-ncp-apigw-api-key") == "fixture-map-secret", "Maps credentials mixed with Search")
        }
        await test("3,000,000th monthly geocode allowed, next blocked") {
            let f = try Fixture(), s = f.store(); await s.raiseUsage(provider: "maps", used: 2999999)
            _ = try await s.address("대전 중구 유천로 35", name: "가상 거래처")
            try await rejects { _ = try await s.address("대전 중구 유천로 36", name: "다른 거래처") }
            try require(f.getCount == 1 && s.quotas["maps"]?.remaining == 0, "Maps free cap exceeded")
        }
        await test("Maps free representative confirmation required") {
            let f = try Fixture(free: false, search: false), s = f.store()
            try await rejects { _ = try await s.address("대전 중구 유천로 35", name: "가상 거래처") }
            try require(f.getCount == 0, "unconfirmed Maps billed")
        }
        await test("storage failure stops before GET dispatch") {
            let f = try Fixture(), s = f.store(); f.writeFails = true
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 0, "GET dispatched after storage failure")
        }
        await test("corrupt persisted state blocks all requests") {
            let f = try Fixture(); f.corruptRead = true; let s = f.store()
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 0 && f.headCount == 0, "corrupt ledger still dispatched")
        }
        await test("trusted-clock failure blocks API before reservation") {
            let f = try Fixture(), s = f.store(); f.headStatus = 503
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 0 && (try f.used("search")) == 0, "untrusted request dispatched")
        }
        await test("authentication failure consumes reservation without retry") {
            let f = try Fixture(), s = f.store(); f.status = 401
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 1 && (try f.used("search")) == 1, "auth failure refunded/retried")
        }
        await test("server 429 blocks subsequent requests despite local balance") {
            let f = try Fixture(), s = f.store(); f.status = 429
            try await rejects { _ = try await s.search("가상 거래처") }
            f.status = 200
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 1 && s.quotas["search"]?.remaining == 0, "server limit ignored")
        }
        await test("cancelled GET remains counted") {
            let f = try Fixture(), s = f.store(); f.cancelGET = true
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 1 && (try f.used("search")) == 1, "cancel refunded")
        }
        await test("Maps throttle 410 pauses briefly without exhausting monthly allowance") {
            let f = try Fixture(), s = f.store(); f.status = 429; f.serverErrorCode = "410"; f.serverErrorMessage = "Throttle Limited"
            try await rejects { _ = try await s.address("대전 중구 유천로 35", name: "가상 거래처") }
            try require(s.quotas["maps"]?.blocked == false, "throttle consumed entire month")
            try await rejects { _ = try await s.address("대전 중구 유천로 35", name: "가상 거래처") }
            try require(f.getCount == 1, "throttle cooldown ignored")
            try await Task.sleep(nanoseconds: 1_100_000_000); f.status = 200
            _ = try await s.address("대전 중구 유천로 35", name: "가상 거래처")
            try require(f.getCount == 2 && (try f.used("maps")) == 2, "throttle never reopened or refunded failed request")
        }
        await test("wrong building address never becomes a coordinate") {
            let f = try Fixture(), s = f.store(); f.mismatchedAddress = true
            try await rejects { _ = try await s.address("대전 중구 유천로 35", name: "가상 거래처") }
            try require(f.getCount == 1 && (try f.used("maps")) == 1, "wrong address not counted or accepted")
        }
        await test("repeated identical address uses memory cache without another charge") {
            let f = try Fixture(), s = f.store()
            let c = try NaverAPIBridge.call("seed", ["name": "가상 거래처", "address": "대전 중구 유천로 35", "now": 1791557400000.0], as: NaverPlaceCapture.self)
            _ = try await s.resolve(c)
            var newer = c; newer.capturedAt = "2026-10-09T14:51:00Z"
            _ = try await s.resolve(newer)
            try require(f.getCount == 1 && (try f.used("maps")) == 1, "cached resolve charged again")
        }
        await test("simultaneous taps share one native gate") {
            let f = try Fixture(), s = f.store(); f.delayGET = true
            let first = Task { try await s.search("가상 거래처") }
            defer { f.getRelease?.resume(); f.getRelease = nil }
            let started = ProcessInfo.processInfo.systemUptime
            while f.getRelease == nil {
                try require(ProcessInfo.processInfo.systemUptime - started < 5, "first GET did not reach the test barrier")
                await Task.yield()
            }
            try await rejects { _ = try await s.search("가상 거래처") }
            f.getRelease?.resume(); f.getRelease = nil
            _ = try await first.value
            try require(f.getCount == 1, "parallel GETs escaped gate")
        }
        await test("Maps account usage survives key rotation") {
            let f = try Fixture(), s = f.store(); await s.raiseUsage(provider: "maps", used: 2999999)
            try require(s.saveSettings(searchID: "", searchSecret: "", mapsID: "new-fixture", mapsSecret: "new-fixture-secret", freeConfirmed: true), "settings not saved")
            await Task.yield()
            while s.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
            let reloaded = f.store(); _ = try await reloaded.address("대전 중구 유천로 35", name: "가상 거래처")
            try require(try f.used("maps") == 3000000, "key rotation reset Maps usage")
        }
        await test("HUB 775,000th monthly search allowed, next blocked despite daily balance") {
            let f = try Fixture(), s = f.store(); await s.raiseUsage(provider: "searchMonth", used: 774999)
            _ = try await s.search("가상 거래처")
            try await rejects { _ = try await s.search("다른 거래처") }
            try require(f.getCount == 1 && s.quotas["searchMonth"]?.remaining == 0 && (try f.used("search")) == 1, "monthly cap escaped or daily partial reservation persisted")
        }
        await test("HUB exhausted month does not persist a partial daily reservation") {
            let f = try Fixture(), s = f.store(); await s.raiseUsage(provider: "searchMonth", used: 775000)
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 0 && (try f.used("search")) == 0 && (try f.used("searchMonth")) == 775000, "monthly rejection partially charged the day")
        }
        await test("HUB temporary-free confirmation required before any billable request") {
            let f = try Fixture(hubFree: false), s = f.store()
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 0 && (try f.used("search")) == 0 && (try f.used("searchMonth")) == 0, "unconfirmed HUB dispatched")
        }
        await test("HUB daily external usage raises monthly usage conservatively") {
            let f = try Fixture(), s = f.store(); await s.raiseUsage(provider: "search", used: 100)
            try require(try f.used("search") == 100 && (try f.used("searchMonth")) == 100, "daily correction lost from month")
            let reloaded = f.store(); _ = try await reloaded.search("가상 거래처")
            try require(try f.used("search") == 101 && (try f.used("searchMonth")) == 101, "restart reset a HUB counter")
        }
        await test("0.14.0 archive migrates to legacy host with its original quota intact") {
            let f = try Fixture(provider: nil)
            var json = try JSONSerialization.jsonObject(with: f.data) as! [String: Any]; json.removeValue(forKey: "searchFreeConfirmed")
            f.data = try JSONSerialization.data(withJSONObject: json)
            let s = f.store(); try require(s.searchProvider == .legacy, "old keys silently became HUB keys")
            await s.raiseUsage(provider: "search", used: 24999)
            let reloaded = f.store(), r = try await reloaded.search("가상 거래처")
            let q = f.requests.last!
            try require(q.url?.host == "openapi.naver.com" && q.url?.path == "/v1/search/local.json" && q.value(forHTTPHeaderField: "X-Naver-Client-Id") == "fixture-client", "legacy key sent to Cloud")
            try require(q.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY-ID") == nil && r[0].capture.geocodeProvider == "NAVER Search", "legacy header/proof changed")
            try require(try f.used("search") == 25000, "old daily count reset")
        }
        await test("switching providers requires a complete fresh credential pair") {
            let f = try Fixture(provider: .legacy), s = f.store()
            try require(!s.saveSettings(searchID: "", searchSecret: "", mapsID: "", mapsSecret: "", freeConfirmed: true, searchProvider: .hub, searchFreeConfirmed: true), "legacy keys reused at new host")
            try require(s.searchProvider == .legacy && f.getCount == 0 && f.headCount == 0, "failed switch changed provider")
        }
        await test("HUB and legacy credentials keep separate quota records when switching") {
            let f = try Fixture(provider: .legacy), s = f.store(); await s.raiseUsage(provider: "search", used: 123)
            try require(s.saveSettings(searchID: "hub-fixture", searchSecret: "hub-fixture-secret", mapsID: "", mapsSecret: "", freeConfirmed: true, searchProvider: .hub, searchFreeConfirmed: true), "provider switch failed")
            await Task.yield(); while s.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
            let reloaded = f.store(); _ = try await reloaded.search("가상 거래처")
            let json = try JSONSerialization.jsonObject(with: f.data) as! [String: Any]
            let accounts = (json["ledger"] as! [String: Any])["accounts"] as! [String: [String: Any]]
            try require(accounts.first(where: { $0.key.hasPrefix("search:") })?.value["used"] as? Int == 123 && (try f.used("search")) == 1, "switch erased or mixed counters")
            try require(f.requests.last!.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY-ID") == "hub-fixture", "new key was not bound to HUB")
        }
        await test("HUB Gateway authentication errors consume one request without retry") {
            let f = try Fixture(), s = f.store(); f.status = 401; f.nestedError = true; f.serverErrorCode = "200"; f.serverErrorMessage = "Authentication Failed"
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 1 && (try f.used("searchMonth")) == 1 && s.quotas["search"]?.blocked == false, "Gateway auth error retried/refunded/exhausted")
        }
        await test("HUB flat Search validation errors preserve the remaining period") {
            let f = try Fixture(), s = f.store(); f.status = 400; f.serverErrorCode = "SE02"; f.serverErrorMessage = "Invalid display value"
            try await rejects { _ = try await s.search("가상 거래처") }; f.status = 200
            _ = try await s.search("가상 거래처")
            try require(f.getCount == 2 && (try f.used("searchMonth")) == 2, "Search validation wrongly blocked period")
        }
        await test("HUB monthly Gateway limit blocks month, not only the day") {
            let f = try Fixture(), s = f.store(); f.status = 429; f.nestedError = true; f.serverErrorCode = "400"; f.serverErrorMessage = "Quota Exceeded"; f.serverErrorDetails = "Monthly quota exceeded"
            try await rejects { _ = try await s.search("가상 거래처") }; f.status = 200
            try await rejects { _ = try await s.search("다른 거래처") }
            try require(f.getCount == 1 && s.quotas["searchMonth"]?.remaining == 0 && (try f.used("search")) == 1, "monthly Gateway limit ignored")
        }
        await test("HUB throttle errors in Gateway details use a short cooldown") {
            let f = try Fixture(), s = f.store(); f.status = 429; f.nestedError = true; f.serverErrorCode = "420"; f.serverErrorDetails = "Rate Limited"
            try await rejects { _ = try await s.search("가상 거래처") }
            try await rejects { _ = try await s.search("가상 거래처") }
            try require(f.getCount == 1 && s.quotas["searchMonth"]?.blocked == false && s.quotas["search"]?.blocked == false, "throttle consumed a day/month or bypassed cooldown")
        }
        await test("HUB decimal WGS84 and address fallback retain HUB proof without a map") {
            let f = try Fixture(maps: false), s = f.store(); f.decimalSearchCoordinate = true
            let result = try await s.address("대전 중구 유천로 35", name: "가상 거래처")
            try require(result.coordinate?.longitude == 127.398 && result.geocodeProvider == "NAVER API HUB" && result.method == "naver_hub_local_search", "fallback lost HUB coordinate proof")
            try require(f.getCount == 1 && (try f.used("searchMonth")) == 1, "fallback made extra requests")
        }
        await test("shared address pins cannot use API geocoding or charge quota") {
            let f = try Fixture(), s = f.store()
            let seed = try NaverAPIBridge.call("seed", ["name": "가상 공유 지점", "address": "대전 중구 가상로 1", "now": 1791557400000.0], as: NaverPlaceCapture.self)
            let shared = try NaverPlaceBridge.call("shared", ["capture": try TMapBridge.object(seed), "url": "https://naver.me/pointA"], as: NaverPlaceCapture.self)
            try await rejects { _ = try await s.resolve(shared) }
            try require(f.getCount == 0 && (try f.used("maps")) == 0, "shared address used representative coordinates or quota")
        }
        let passed = checks.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["passed": passed, "total": checks.count, "checks": checks, "live_api": false, "browser_or_map_required": false]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if passed != checks.count { exit(1) }
    }
}
