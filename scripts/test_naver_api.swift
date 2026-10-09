// Test-only model dependencies. The shipped store, models and JS bridges compile below.
import Foundation

struct TMapCoordinate: Codable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
struct MapRoutePoint: Codable { var token: String; var name: String }
struct TestStop { var id = ""; var naverPlace: NaverPlaceCapture? }
struct DeliveryPlan { var naverOrigin: NaverPlaceCapture?; var visits: [TestStop] = []; var destination: TestStop? }
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
    var headStatus = 200
    var cancelGET = false
    var delayGET = false
    var mismatchedAddress = false
    var requests: [URLRequest] = []
    init(free: Bool = true, search: Bool = true, maps: Bool = true) throws {
        data = try JSONSerialization.data(withJSONObject: ["version": 1, "searchID": search ? "fixture-client" : "", "searchSecret": search ? "fixture-secret" : "", "mapsID": maps ? "fixture-maps" : "", "mapsSecret": maps ? "fixture-map-secret" : "", "mapsFreeConfirmed": free, "ledger": ["version": 1, "accounts": [:]]])
    }
    func store() -> NaverAPIStore {
        NaverAPIStore(read: { self.corruptRead ? Data("broken".utf8) : self.data }, write: {
            if self.writeFails { throw PlannerFailure.message("fixture storage failure") }; self.data = $0
        }, transport: { request in try await self.respond(request) })
    }
    func used(_ provider: String) throws -> Int {
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ledger = json["ledger"] as! [String: Any], accounts = ledger["accounts"] as! [String: [String: Any]]
        return accounts.first(where: { $0.key.hasPrefix(provider == "search" ? "search:" : "maps-") })?.value["used"] as? Int ?? 0
    }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let head = request.httpMethod == "HEAD"
        if head { headCount += 1 } else {
            getCount += 1
            let provider = request.url!.host == "openapi.naver.com" ? "search" : "maps"
            try require(try used(provider) > 0, "request dispatched before persisted reservation")
            if cancelGET { throw CancellationError() }
            if delayGET { try await Task.sleep(nanoseconds: 120_000_000) }
        }
        let address = mismatchedAddress ? "대전 중구 유천로 350" : "대전광역시 중구 유천로 35"
        let json: [String: Any]
        if head { json = [:] }
        else if status != 200 { json = ["errorCode": status == 429 ? "012" : "024", "errorMessage": "fixture error"] }
        else if request.url!.host == "openapi.naver.com" {
            json = ["items": [["title": "<b>가상</b> 거래처", "roadAddress": address, "address": "대전 중구 유천동 100", "category": "배송", "mapx": "1273980000", "mapy": "363160000"]]]
        } else {
            json = ["status": "OK", "addresses": [["roadAddress": address, "jibunAddress": "대전 중구 유천동 100", "x": "127.398", "y": "36.316"]]]
        }
        return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: head ? headStatus : status, httpVersion: "HTTP/1.1", headerFields: ["Date": "Fri, 09 Oct 2026 14:50:00 GMT", "Age": "0"])!)
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
        await test("official local endpoint, headers and persist-before-dispatch") {
            let f = try Fixture(), s = f.store(), r = try await s.search("가상 거래처 대전")
            try require(r.count == 1 && r[0].capture.coordinate?.longitude == 127.398, "bad coordinate")
            let q = f.requests.last!
            try require(q.url?.host == "openapi.naver.com" && q.url?.path == "/v1/search/local.json", "wrong local endpoint")
            try require(q.value(forHTTPHeaderField: "X-Naver-Client-Id") == "fixture-client" && q.value(forHTTPHeaderField: "X-Naver-Client-Secret") == "fixture-secret", "wrong headers")
            try require(try f.used("search") == 1 && f.getCount == 1, "wrong reservation")
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
        await test("wrong building address never becomes a coordinate") {
            let f = try Fixture(), s = f.store(); f.mismatchedAddress = true
            try await rejects { _ = try await s.address("대전 중구 유천로 35", name: "가상 거래처") }
            try require(f.getCount == 1 && (try f.used("maps")) == 1, "wrong address not counted or accepted")
        }
        await test("repeated identical address uses memory cache without another charge") {
            let f = try Fixture(), s = f.store()
            let c = try NaverAPIBridge.call("seed", ["name": "가상 거래처", "address": "대전 중구 유천로 35", "now": 1791557400000.0], as: NaverPlaceCapture.self)
            _ = try await s.resolve(c); _ = try await s.resolve(c)
            try require(f.getCount == 1 && (try f.used("maps")) == 1, "cached resolve charged again")
        }
        await test("simultaneous taps share one native gate") {
            let f = try Fixture(), s = f.store(); f.delayGET = true
            let first = Task { try await s.search("가상 거래처") }
            try await Task.sleep(nanoseconds: 20_000_000)
            try await rejects { _ = try await s.search("가상 거래처") }
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
        let passed = checks.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["passed": passed, "total": checks.count, "checks": checks, "live_api": false, "browser_or_map_required": false]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if passed != checks.count { exit(1) }
    }
}
