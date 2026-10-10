import AppKit
import WebKit
import Foundation

// Exercise the SAME embedded request/reply scripts in real WKWebView with
// local, different-origin iframe fixtures. No account or external site access.
@MainActor
final class FrameChecks: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let window: NSWindow
    var checks = 0
    let parent = "http://127.0.0.1:8349"
    override init() {
        let configuration = WKWebViewConfiguration()
        let bridge = Self.fixture(NaverFrameBridgeScript.source)
        let detail = Self.fixture(NaverPlaceDetailScript.source)
        let list = Self.fixture(NaverSavedListScript.source)
        configuration.userContentController.addUserScript(WKUserScript(source: "(" + bridge + ")(" + detail + "," + list + ");", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 700), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 393, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        view.navigationDelegate = self
        window.contentView = view
        window.orderFront(nil)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { print("FIXTURE_NAVIGATION_ERROR \(error)") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { print("FIXTURE_NAVIGATION_ERROR \(error)") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { print("FIXTURE_MAIN_LOADED \(webView.url?.absoluteString ?? "nil")") }
    static func fixture(_ source: String) -> String {
        source.replacingOccurrences(of: "location.hostname==='pcmap.place.naver.com'?", with: "location.port==='8350'?")
            .replacingOccurrences(of: "'https:'", with: "'http:'")
            .replacingOccurrences(of: "https://map.naver.com", with: "http://127.0.0.1:8349")
            .replacingOccurrences(of: "https://pcmap.place.naver.com", with: "http://127.0.0.1:8350")
            .replacingOccurrences(of: "https://pages.map.naver.com", with: "http://127.0.0.1:8351")
            .replacingOccurrences(of: "'map.naver.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'pcmap.place.naver.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'pages.map.naver.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'map.pstatic.net'", with: "'127.0.0.1'")
            .replacingOccurrences(of: #"https:\/\/map\.pstatic\.net"#, with: #"http:\/\/127\.0\.0\.1:8349"#)
    }
    func evaluate(_ body: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let raw: Any = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
        guard let string = raw as? String, let data = string.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "fixture-json", code: 1) }
        return object
    }
    func request(_ kind: String, command: String = "read", args: [String: Any] = [:], id: String = UUID().uuidString) async throws -> [String: Any] {
        try await evaluate("return await (" + Self.fixture(NaverFrameRequestScript.source) + ")(kind, command, requestID, args);",
                           ["kind": kind, "command": command, "requestID": id, "args": args])
    }
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw NSError(domain: name, code: 1) }
        checks += 1; print("PASS \(name)")
    }
    func run() async {
        do {
            try check(try NaverSharedLink.parse("[네이버 지도]\n거래처\nhttps://naver.me/5eUPxjWq").kind == .short, "shared text extracts one short link")
            try check(try NaverSharedLink.parse("https://m.place.naver.com/restaurant/101/home").kind == .place("101"), "mobile restaurant share keeps exact POI ID")
            try check(try NaverSharedLink.parse("https://map.naver.com/p/search/거래처/place/102?c=14.00,0,0,0,dh").kind == .place("102"), "search result share keeps selected POI ID")
            try check(try NaverSharedLink.parse("https://map.naver.com/p/favorite/myPlace/folder/fixture-folder/pc/place/101").kind == .folder("fixture-folder"), "saved folder share imports its folder")
            try check(NaverSharedLink.target(URL(string: "https://map.naver.com.evil.test/p/entry/place/101")!) == nil, "lookalike host is rejected")
            try check(NaverSharedLink.target(URL(string: "https://map.naver.com/p?c=127.4,36.3,14")!) == nil, "map center is not a place coordinate")
            let coordinateURL = try NaverSharedLink.parse("https://map.naver.com/p/entry/place/101?lng=1&lat=2")
            try check(coordinateURL.url.absoluteString == "https://map.naver.com/p/entry/place/101?lng=1&lat=2", "original position parameters are retained without trusting them as coordinates")
            var multipleRejected = false
            do { _ = try NaverSharedLink.parse("https://naver.me/abc123 https://naver.me/def456") } catch { multipleRejected = true }
            try check(multipleRejected, "multiple place links are rejected")
            try check(try NaverSharedLink.parse("[네이버 지도]\n대전 중구 가상로446번길 61\nhttps://naver.me/address1").kind == .short, "address-only share title does not choose a point or bypass its URL")
            try check(try NaverSharedLink.parse("[네이버지도] 대전 중구 가상로 7-6 https://naver.me/address2").kind == .short, "inline address title also preserves short-link resolution")
            try check(try NaverSharedLink.parse("[네이버 지도]\n가상 거래처\n대전 중구 가상로 1\nhttps://naver.me/business1").kind == .short, "business share is not reinterpreted as an address title")
            try check(try NaverSharedLink.parse("[네이버 지도]\n대전 중구 가상로 1\nhttps://map.naver.com/p/entry/place/101").kind == .place("101"), "explicit POI link takes precedence over address title")
            try check(try NaverSharedLink.parse("[네이버 지도]\n대전 중구 가상로 1\nhttps://map.naver.com/p/favorite/myPlace/folder/fixture-folder").kind == .folder("fixture-folder"), "folder link takes precedence over address title")
            let addressURL = URL(string: "https://map.naver.com/v5/search/대전 중구 가상로 7-6?c=127.4,36.3,14&lng=1&lat=2")!
            let addressTarget = NaverSharedLink.target(addressURL)
            try check(addressTarget?.kind == .mapSelection && addressTarget?.url == addressURL, "selected address URL keeps all position parameters for marker verification")
            try check(NaverSharedLink.target(URL(string: "https://map.naver.com/p/search/대전 음식점?lng=127.4&lat=36.3")!)?.kind == .mapSelection, "search URLs are navigation only and still require a selected marker")
            try check(try NaverSharedLink.parse("[네이버 지도]\n가상로 7-6\nhttps://naver.me/partial1").kind == .short, "incomplete address share remains a link for selected-place verification")
            try check(NaverSharedLink.roadAddress("대전광역시 중구 가상로 7-6, 2층 (가상동)") == "대전광역시 중구 가상로 7-6", "unit suffix is omitted from a complete shared road address")
            try check(NaverSharedLink.roadAddress("세종특별자치시 가상로 12") == "세종특별자치시 가상로 12" && NaverSharedLink.roadAddress("경기도 가상시 가상구 가상로 12") != nil, "Sejong and province-city-district address forms")
            var forgedRejected = false
            do { _ = try NaverSharedLink.parse("[네이버 지도]\n대전 중구 가상로 1\nhttps://map.naver.com.evil.test/p/search/주소") } catch { forgedRejected = true }
            try check(forgedRejected, "NAVER-looking address title cannot authorize an unrelated host")
            view.load(URLRequest(url: URL(string: parent + "/main")!))
            let deadline = Date().addingTimeInterval(12)
            var ready = false
            while Date() < deadline {
                let state = try? await evaluate("return JSON.stringify({ok:true,ready:location.pathname==='/main'&&!!document.querySelector('#entryIframe'),url:location.href,state:document.readyState});")
                print("FIXTURE_READY_STATE \(String(describing: state)) URL \(view.url?.absoluteString ?? "nil") loading \(view.isLoading)")
                if state?["ready"] as? Bool == true { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready else { throw NSError(domain: "local fixture main page not loaded", code: 1) }
            let first = try await request("place")
            print("FIRST_FRAME_RESULT \(first)")
            try check(first["ok"] as? Bool == true && first["placeID"] as? String == "101", "iPhone-width cross-origin restaurant frame")
            try check(first["address"] as? String == "서울 중구 세종대로 1", "detail address arrives without WKFrameInfo")
            _ = try await evaluate("document.querySelector('#entryIframe').src='http://127.0.0.1:8350/place/102/home'; return JSON.stringify({ok:true});")
            let second = try await request("place")
            try check(second["placeID"] as? String == "102" && second["name"] as? String == "두 번째 거래처", "new iframe document replaces previous place")
            let list = try await request("list")
            try check(list["ok"] as? Bool == true && list["total"] as? Int == 25 && (list["rows"] as? [[String: Any]])?.count == 25, "scroll loads all 25 places instead of initial 20")
            let rows = list["rows"] as! [[String: Any]], id = UUID().uuidString
            let row = rows[0]
            let args: [String: Any] = ["folderID": "fixture-folder", "index": 0, "key": row["key"]!]
            let selected = try await request("list", command: "select", args: args, id: id)
            _ = try await request("list", command: "select", args: args, id: id)
            try check(selected["ok"] as? Bool == true, "saved list selection returns matching row")
            try await Task.sleep(nanoseconds: 250_000_000)
            let clicked = try await evaluate("return JSON.stringify({ok:true,count:Number(document.querySelector('#clickCount').textContent)});")
            try check(clicked["count"] as? Int == 1, "repeated nonce clicks a saved place only once")
            let changed = try await request("list", command: "select", args: ["folderID": "fixture-folder", "index": 0, "key": "changed"])
            try check(changed["ok"] as? Bool == false, "changed list item is rejected")
            let panel = try await evaluate("return await (" + Self.fixture(NaverMapPanelScript.source) + ")(true);")
            try check(panel["mapVisible"] as? Bool == true, "phone map button collapses full-width search panel")
            let opened = try await evaluate("return await (" + Self.fixture(NaverMapPanelScript.source) + ")(false);")
            try check(opened["mapVisible"] as? Bool == false, "place button restores search panel")
            view.load(URLRequest(url: URL(string: parent + "/address")!))
            let addressDeadline = Date().addingTimeInterval(12)
            var addressReady = false
            while Date() < addressDeadline {
                let state = try? await evaluate("return JSON.stringify({ok:true,ready:location.pathname==='/address'&&!!document.querySelector('#pin')});")
                if state?["ready"] as? Bool == true && !view.isLoading { addressReady = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard addressReady else { throw NSError(domain: "local selected address fixture not loaded", code: 1) }
            let rootBody = "return (" + Self.fixture(NaverPlaceRootScript.source) + ")();"
            let addressPoint = try await evaluate(rootBody)
            try check(addressPoint["ok"] as? Bool == true && addressPoint["kind"] as? String == "address" && addressPoint["placeID"] as? String == "", "shared address panel is readable without a registered POI")
            let expected = try await evaluate("const m=document.querySelector('.mantle_map'); return JSON.stringify({longitude:Number(m.dataset.longitude),latitude:Number(m.dataset.latitude)});")
            let coordinate = addressPoint["coordinate"] as? [String: Double]
            try check(coordinate != nil && abs(coordinate!["longitude"]! - (expected["longitude"] as! Double)) < 1e-10 && abs(coordinate!["latitude"]! - (expected["latitude"] as! Double)) < 1e-10, "selected anchor and actual tile rectangles supply the exact fixture point")
            _ = try await evaluate("document.querySelector('#pin').style.left='216px'; return JSON.stringify({ok:true});")
            let otherPoint = try await evaluate(rootBody), otherCoordinate = otherPoint["coordinate"] as? [String: Double]
            try check(otherPoint["name"] as? String == addressPoint["name"] as? String && otherPoint["address"] as? String == addressPoint["address"] as? String && otherCoordinate?["longitude"] != coordinate?["longitude"], "identical address labels with different pins produce different coordinates")
            _ = try await evaluate("document.querySelector('#pin').style.display='none'; return JSON.stringify({ok:true});")
            let hidden = try await evaluate(rootBody)
            try check(hidden["kind"] as? String == "address" && hidden["coordinate"] is NSNull, "hidden pin keeps the address but cannot invent building coordinates")
            _ = try await evaluate("const p=document.querySelector('#pin');p.style.display='';const q=p.cloneNode(true);q.id='secondPin';p.parentElement.append(q);return JSON.stringify({ok:true});")
            let ambiguous = try await evaluate(rootBody)
            try check(ambiguous["coordinate"] is NSNull, "multiple selected pins cannot select an arbitrary coordinate")
            print("NATIVE_NAVER_FRAME_CHECKS \(checks)/\(checks)"); exit(0)
        } catch { print("FAIL native Naver frame check: \(error)"); exit(1) }
    }
}
@main
struct NativeFrameTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let tests = FrameChecks()
        Task { await tests.run() }
        app.run()
    }
}
