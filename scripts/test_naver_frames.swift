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
            try check(coordinateURL.url.absoluteString == "https://map.naver.com/p/entry/place/101", "unverified query coordinates are discarded")
            var multipleRejected = false
            do { _ = try NaverSharedLink.parse("https://naver.me/abc123 https://naver.me/def456") } catch { multipleRejected = true }
            try check(multipleRejected, "multiple place links are rejected")
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
