import Foundation

// Type-only planner dependencies. Compile the shipped HTTP resolver and JS
// validation bridge. All share tokens and locations below are synthetic.
struct TMapCoordinate: Codable { var longitude: Double; var latitude: Double }
struct MapRoutePoint: Codable { var token: String; var name: String }
struct TestStop: Codable { var id = ""; var naverPlace: NaverPlaceCapture? }
struct DeliveryPlan: Codable { var naverOrigin: NaverPlaceCapture?; var visits: [TestStop] = []; var destination: TestStop? }
enum PlannerFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
private func require(_ value: Bool, _ message: String) throws { if !value { throw PlannerFailure.message(message) } }
private func pinURL(_ longitude: String = "127.4000001") -> URL {
    var parts = URLComponents(string: "https://map.naver.com/")!
    parts.queryItems = [URLQueryItem(name: "appMenu", value: "location"), URLQueryItem(name: "menu", value: "location"),
        URLQueryItem(name: "lng", value: longitude), URLQueryItem(name: "lat", value: "36.3000001"),
        URLQueryItem(name: "address", value: "대전 중구 가상로 1"), URLQueryItem(name: "query", value: "대전 중구 가상로 1"),
        URLQueryItem(name: "title", value: "대전 중구 가상로 1")]
    return parts.url!
}
@MainActor private final class Fixture {
    var requests: [URLRequest] = []
    var status = 307
    var location = pinURL().absoluteString
    var responseURL: URL?
    var body = Data()
    var next: ((URLRequest) throws -> String)?
    var cancelled = false
    func resolve(_ text: String = "[네이버지도]\n무시할 주소 999\nhttps://naver.me/fixture1") async throws -> NaverSharedLinkResolver.Result {
        let resolver = NaverSharedLinkResolver { request in
            self.requests.append(request)
            if self.cancelled { throw CancellationError() }
            let location = try self.next?(request) ?? self.location
            return (self.body, HTTPURLResponse(url: self.responseURL ?? request.url!, statusCode: self.status,
                httpVersion: "HTTP/1.1", headerFields: ["Location": location])!)
        }
        return try await resolver.resolve(NaverSharedLink.parse(text))
    }
    func pin(_ text: String = "https://naver.me/fixture1") async throws -> NaverPlaceCapture {
        guard case .pin(let value) = try await resolve(text) else { throw PlannerFailure.message("expected selected pin") }
        return value
    }
}

@main struct SharedLinkNativeChecks {
    @MainActor static func main() async {
        var checks: [[String: Any]] = []
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); checks.append(["name": name, "passed": true]) }
            catch { checks.append(["name": name, "passed": false, "error": error.localizedDescription]) }
        }
        func rejects(_ fixture: Fixture, _ text: String = "https://naver.me/fixture1") async throws {
            do { _ = try await fixture.resolve(text) } catch { return }
            throw PlannerFailure.message("expected rejection")
        }
        await test("307 Location preserves exact selected pin rather than parsing a map page") {
            let f = Fixture(), c = try await f.pin()
            try require(c.coordinate?.longitude == 127.4000001 && c.coordinate?.latitude == 36.3000001, "coordinate precision")
            try require(f.requests.count == 1 && c.method == "naver_shared_link_coordinate", "unnecessary map request")
            try require(c.sharedLinkURL == "https://naver.me/fixture1" && c.sharedPinEvidence?.resolvedURL == f.location, "redirect evidence")
        }
        await test("pasted front address cannot replace response point or address") {
            let f = Fixture()
            guard case .pin(let c) = try await f.resolve() else { throw PlannerFailure.message("expected pin") }
            try require(c.address == "대전 중구 가상로 1", "pasted title selected an address")
        }
        await test("direct location URL requires no network or API credential") {
            let f = Fixture(), c = try await f.pin(pinURL().absoluteString)
            try require(f.requests.isEmpty && c.coordinate?.longitude == 127.4000001, "direct pin requested a page")
        }
        await test("HTTP share requests carry no API key, cookie or authorization") {
            let f = Fixture(); _ = try await f.pin(); let r = f.requests[0]
            try require(r.httpMethod == "GET" && r.timeoutInterval <= 10, "request boundary")
            for header in ["Cookie", "Authorization", "X-NCP-APIGW-API-KEY", "X-Naver-Client-Secret"] {
                try require(r.value(forHTTPHeaderField: header) == nil, "credential leaked")
            }
        }
        await test("all standard HTTP redirect statuses retain pin data") {
            for status in [301, 302, 303, 307, 308] { let f = Fixture(); f.status = status; _ = try await f.pin() }
        }
        await test("relative short-link hop is resolved before exact pin") {
            let f = Fixture(); f.next = { request in request.url!.path == "/fixture1" ? "/fixture2" : pinURL().absoluteString }
            let c = try await f.pin(); try require(f.requests.count == 2 && c.sharedLinkURL == "https://naver.me/fixture1", "hop provenance")
        }
        await test("rendered HTML and embedded coordinate text cannot substitute for Location") {
            let f = Fixture(); f.status = 200; f.body = Data("<script>lat=36.3;lng=127.4</script>".utf8)
            try await rejects(f)
        }
        await test("external, plaintext and app-scheme redirect targets are rejected before dispatch") {
            for target in ["https://example.com/point", "http://map.naver.com/?lat=36.3&lng=127.4", "nmap://place?lat=36.3&lng=127.4"] {
                let f = Fixture(); f.location = target; try await rejects(f); try require(f.requests.count == 1, "untrusted request dispatched")
            }
        }
        await test("arbitrary coordinates without NAVER location-share type are rejected") {
            let f = Fixture(); f.location = "https://map.naver.com/?lat=36.3&lng=127.4"
            try await rejects(f); try require(f.requests.count == 1, "map page loaded")
        }
        await test("duplicate selected-coordinate query parameters are rejected") {
            let f = Fixture(); f.location += "&lng=127.5"; try await rejects(f)
        }
        await test("redirect loop is bounded") {
            let f = Fixture(); f.location = "https://naver.me/fixture1"; try await rejects(f)
            try require(f.requests.count == 1, "loop re-requested same URL")
        }
        await test("redirect chains stop after six HTTP requests") {
            let f = Fixture(); var hop = 0
            f.next = { _ in hop += 1; return "https://naver.me/hop\(hop)" }; try await rejects(f)
            try require(f.requests.count == 6, "redirect count")
        }
        await test("transport cannot silently replace original response URL") {
            let f = Fixture(); f.responseURL = URL(string: "https://naver.me/another")!; try await rejects(f)
        }
        await test("cancelled requests do not produce a capture") {
            let f = Fixture(); f.cancelled = true; try await rejects(f)
        }
        await test("place and folder links explicitly request visible web workflow without HTTP or geocoding") {
            for link in ["https://map.naver.com/p/entry/place/101", "https://map.naver.com/p/favorite/myPlace/folder/fixture-folder"] {
                let f = Fixture(); guard case .web = try await f.resolve(link) else { throw PlannerFailure.message("expected web workflow") }
                try require(f.requests.isEmpty, "unnecessary HTTP request")
            }
        }
        await test("saved capture round-trip retains HTTP evidence and exact precision") {
            let c = try await Fixture().pin(), data = try JSONEncoder().encode(c)
            let copy = try JSONDecoder().decode(NaverPlaceCapture.self, from: data)
            try require(copy.sharedPinEvidence?.longitude == "127.4000001" && copy.coordinate?.latitude == 36.3000001, "codable evidence")
            let object = try JSONSerialization.jsonObject(with: data)
            let checked = try NaverPlaceBridge.call("validate", ["capture": object], as: NaverPlaceCapture.self)
            try require(checked.coordinate?.longitude == c.coordinate?.longitude, "persisted validation")
        }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": checks.filter { $0["passed"] as? Bool == true }.count, "total": checks.count, "checks": checks], options: [.sortedKeys]), as: UTF8.self))
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}
