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
private func siteURL(_ longitude: String = "127.4000001", name: String = "가상식당 가상점") -> URL {
    var parts = URLComponents(string: "https://map.naver.com/")!
    parts.queryItems = [URLQueryItem(name: "pinId", value: "101"), URLQueryItem(name: "pinType", value: "site"),
        URLQueryItem(name: "menu", value: "location"), URLQueryItem(name: "appMenu", value: "location"),
        URLQueryItem(name: "title", value: name), URLQueryItem(name: "lat", value: "36.3000001"),
        URLQueryItem(name: "lng", value: longitude)]
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
    func resolver() -> NaverSharedLinkResolver {
        NaverSharedLinkResolver { request in
            self.requests.append(request)
            if self.cancelled { throw CancellationError() }
            let location = try self.next?(request) ?? self.location
            return (self.body, HTTPURLResponse(url: self.responseURL ?? request.url!, statusCode: self.status,
                httpVersion: "HTTP/1.1", headerFields: ["Location": location])!)
        }
    }
    func resolve(_ text: String = "[네이버지도]\n무시할 주소 999\nhttps://naver.me/fixture1") async throws -> NaverSharedLinkResolver.Result {
        try await resolver().resolve(NaverSharedLink.parse(text))
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
        await test("business full share keeps pasted road address and exact HTTP site coordinate") {
            let f = Fixture(); f.location = siteURL().absoluteString
            let c = try await f.pin("[네이버지도]\n가상식당 가상점\n대전 유성구 가상로 11 \nhttps://naver.me/fixtureSite ")
            try require(c.kind == "place" && c.placeID == "101" && c.name == "가상식당 가상점", "site identity")
            try require(c.address == "대전 유성구 가상로 11" && c.coordinate?.longitude == 127.4000001, "share metadata altered coordinate")
            try require(f.requests.count == 1 && c.sharedPinEvidence?.sharedAddress == c.address, "site loaded browser or lost provenance")
        }
        await test("inline and multiline business shares preserve the same metadata") {
            let f = Fixture(); f.location = siteURL().absoluteString
            let c = try await f.pin("[네이버 지도] 가상식당 가상점 대전 유성구 가상로 11 https://naver.me/fixtureSite")
            try require(c.address == "대전 유성구 가상로 11" && c.sharedPinEvidence?.sharedName == c.name, "inline share")
        }
        await test("bare business short link is readable with missing address made explicit") {
            let f = Fixture(); f.location = siteURL().absoluteString
            let c = try await f.pin(); try require(c.kind == "place" && c.address.isEmpty && c.coordinate != nil, "address incorrectly required")
        }
        await test("pasted business label from another site is rejected") {
            let f = Fixture(); f.location = siteURL().absoluteString
            try await rejects(f, "[네이버지도]\n다른식당\n대전 유성구 가상로 11\nhttps://naver.me/fixtureSite")
        }
        await test("business HTTP evidence and metadata survive Codable round trip") {
            let f = Fixture(); f.location = siteURL().absoluteString
            let c = try await f.pin("[네이버지도]\n가상식당 가상점\n대전 유성구 가상로 11\nhttps://naver.me/fixtureSite")
            let data = try JSONEncoder().encode(c), copy = try JSONDecoder().decode(NaverPlaceCapture.self, from: data)
            try require(copy.sharedPinEvidence?.sharedAddress == c.address && copy.matchesSelection(c), "business evidence lost")
        }
        await test("same business ID with a changed selected point fails native selection check") {
            let f = Fixture(); f.location = siteURL().absoluteString; let a = try await f.pin()
            f.location = siteURL("127.4000002").absoluteString; let b = try await f.pin()
            try require(a.placeID == b.placeID && !a.matchesSelection(b) && a.id != b.id, "place ID hid a coordinate change")
        }
        await test("revalidation reuses retained share metadata while refetching only the pin response") {
            let f = Fixture(); f.location = siteURL().absoluteString
            let c = try await f.pin("[네이버지도]\n가상식당 가상점\n대전 유성구 가상로 11\nhttps://naver.me/fixtureSite")
            var target = try NaverSharedLink.parse(c.sharedLinkURL!)
            target.sharedAddress = c.sharedPinEvidence?.sharedAddress; target.sharedName = c.sharedPinEvidence?.sharedName
            let resolver = NaverSharedLinkResolver { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": siteURL().absoluteString])!)
            }
            guard case .pin(let fresh) = try await resolver.resolve(target) else { throw PlannerFailure.message("expected pin") }
            let first = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)), second = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh))
            let check = try NaverPlaceBridge.call("sameSelection", ["capture": first, "fresh": second, "useCoordinate": true], as: NaverPlaceSelectionCheck.self)
            try require(check.same, "retained address prevented HTTP revalidation")
        }
        await test("business share with an unparenthesized building name retains the full address and HTTP coordinate") {
            let name = "학교법인 가상학원 가상대학교병원", address = "대전 서구 가상대로 95 가상대학교병원"
            let f = Fixture(); f.location = siteURL(name: name).absoluteString
            let c = try await f.pin("[네이버지도]\n\(name)\n\(address)\nhttps://naver.me/fixtureHospital")
            try require(c.name == name && c.address == address && c.roadAddress == address && c.sharedPinEvidence?.sharedAddress == address, "building address omitted or truncated")
            try require(c.coordinate?.longitude == 127.4000001 && c.coordinate?.latitude == 36.3000001 && f.requests.count == 1 && c.method == "naver_shared_link_coordinate", "building name changed the pin")
        }
        await test("inline building address and unit suffix remain share metadata") {
            let f = Fixture(); f.location = siteURL().absoluteString
            let address = "대전 유성구 가상로 11 가상빌딩 2층 201호"
            let c = try await f.pin("[네이버 지도] 가상식당 가상점 \(address) https://naver.me/fixtureSite")
            try require(c.address == address && c.sharedPinEvidence?.sharedName == c.name, "inline building or unit omitted")
            try require(NaverSharedLink.roadAddress(c.address) == "대전 유성구 가상로 11", "unit changed the road validation key")
        }
        await test("building-name support still requires a complete road address and building number boundary") {
            try require(NaverSharedLink.roadAddress("대전 서구 가상대로 95-1 가상병원") == "대전 서구 가상대로 95-1", "building subnumber omitted")
            for incomplete in ["대전 서구 가상대로 가상병원", "대전 서구 가상대로 95A", "대전 서구 가상대로 1234567 가상병원", "서구 가상대로 95 가상병원"] {
                try require(NaverSharedLink.roadAddress(incomplete) == nil, "incomplete road or partial number accepted")
            }
        }
        await test("full building address survives persistence and browserless HTTP revalidation") {
            let f = Fixture(); f.location = siteURL().absoluteString
            let address = "대전 유성구 가상로 11 가상빌딩 (가상동)"
            let c = try await f.pin("[네이버지도]\n가상식당 가상점\n\(address)\nhttps://naver.me/fixtureSite")
            let data = try JSONEncoder().encode(c), copy = try JSONDecoder().decode(NaverPlaceCapture.self, from: data)
            var target = try NaverSharedLink.parse(copy.sharedLinkURL!)
            target.sharedName = copy.sharedPinEvidence?.sharedName; target.sharedAddress = copy.sharedPinEvidence?.sharedAddress
            let resolver = NaverSharedLinkResolver { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": siteURL().absoluteString])!)
            }
            guard case .pin(let fresh) = try await resolver.resolve(target) else { throw PlannerFailure.message("expected pin") }
            let first = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)), second = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh))
            let check = try NaverPlaceBridge.call("sameSelection", ["capture": first, "fresh": second, "useCoordinate": true], as: NaverPlaceSelectionCheck.self)
            try require(copy.address == address && fresh.address == address && check.same && copy.matchesSelection(fresh), "building metadata did not round-trip")
        }
        await test("coordinate editing retains all response precision and ignores a front address") {
            let f = Fixture(); f.location = pinURL("127.400000123456").absoluteString
            guard case .coordinate(let point) = try await f.resolver().resolveCoordinate("[네이버지도]\n대전 중구 다른로 999\nhttps://naver.me/fixture1") else { throw PlannerFailure.message("expected point") }
            try require(point.longitude == 127.400000123456 && point.latitude == 36.3000001, "link precision or front-address substitution")
            try require(f.requests.count == 1, "unnecessary coordinate lookup")
        }
        await test("coordinate editing keeps two selected points with the same address distinct") {
            let f = Fixture()
            guard case .coordinate(let first) = try await f.resolver().resolveCoordinate(pinURL("127.4000001").absoluteString),
                  case .coordinate(let second) = try await f.resolver().resolveCoordinate(pinURL("127.4009009").absoluteString) else { throw PlannerFailure.message("expected points") }
            try require(first.longitude != second.longitude && f.requests.isEmpty, "same address merged or geocoded")
        }
        await test("coordinate editing passes a registered-place ID to the exact selected-place reader") {
            let f = Fixture()
            guard case .place(let target, let original) = try await f.resolver().resolveCoordinate("https://m.place.naver.com/restaurant/123456789/home") else { throw PlannerFailure.message("expected selected-place reader") }
            try require(target.kind == .place("123456789") && original == "https://map.naver.com/p/entry/place/123456789" && f.requests.isEmpty, "place identity changed")
        }
        await test("coordinate editing rejects direct and shortened saved folders without importing any record") {
            let f = Fixture()
            do { _ = try await f.resolver().resolveCoordinate("https://map.naver.com/p/favorite/myPlace/folder/fixture"); throw PlannerFailure.message("accepted folder") }
            catch { try require(error.localizedDescription.contains("지점 하나"), "unexpected folder error") }
            try require(f.requests.isEmpty, "direct folder requested")
            f.location = "https://map.naver.com/p/favorite/myPlace/folder/fixture"
            do { _ = try await f.resolver().resolveCoordinate("https://naver.me/fixture1"); throw PlannerFailure.message("accepted shortened folder") }
            catch { try require(error.localizedDescription.contains("지점 하나"), "unexpected shortened-folder error") }
            try require(f.requests.count == 1, "followed folder into a list")
        }
        await test("coordinate editing rejects multiple links and an arbitrary map center") {
            let f = Fixture()
            for text in ["https://naver.me/fixture1 https://naver.me/fixture2", "https://map.naver.com/p/?c=127.4,36.3,15"] {
                var rejected = false
                do { _ = try await f.resolver().resolveCoordinate(text) } catch { rejected = true }
                try require(rejected, "accepted ambiguous coordinate")
            }
            try require(f.requests.isEmpty, "requested ambiguous link")
        }
        await test("coordinate editing retains cancellation instead of returning a replacement coordinate") {
            let f = Fixture(); f.cancelled = true
            do { _ = try await f.resolver().resolveCoordinate("https://naver.me/fixture1"); throw PlannerFailure.message("ignored cancellation") }
            catch is CancellationError { }
        }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": checks.filter { $0["passed"] as? Bool == true }.count, "total": checks.count, "checks": checks], options: [.sortedKeys]), as: UTF8.self))
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}
