import AppKit
import WebKit
import Foundation

// Exercise the SAME embedded request/reply scripts in real WKWebView with
// local, different-origin iframe fixtures. No account or external site access.
@MainActor
final class FrameChecks {
    let view: WKWebView
    let window: NSWindow
    var checks = 0
    let parent = "http://localhost:8349"
    init() {
        let configuration = WKWebViewConfiguration()
        let bridge = Self.fixture(NaverFrameBridgeScript.source)
        let detail = Self.fixture(NaverPlaceDetailScript.source)
        let list = Self.fixture(NaverSavedListScript.source)
        configuration.userContentController.addUserScript(WKUserScript(source: "(" + bridge + ")(" + detail + "," + list + ");", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 700), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 393, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
    }
    static func fixture(_ source: String) -> String {
        source.replacingOccurrences(of: "'https:'", with: "'http:'")
            .replacingOccurrences(of: "https://map.naver.com", with: "http://localhost:8349")
            .replacingOccurrences(of: "https://pcmap.place.naver.com", with: "http://127.0.0.1:8349")
            .replacingOccurrences(of: "https://pages.map.naver.com", with: "http://127.0.0.2:8349")
            .replacingOccurrences(of: "'map.naver.com'", with: "'localhost'")
            .replacingOccurrences(of: "'pcmap.place.naver.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'pages.map.naver.com'", with: "'127.0.0.2'")
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
            view.load(URLRequest(url: URL(string: parent + "/main")!))
            let deadline = Date().addingTimeInterval(12)
            var ready = false
            while Date() < deadline {
                let state = try? await evaluate("return JSON.stringify({ok:true,ready:location.pathname==='/main'&&!!document.querySelector('#entryIframe')});")
                if state?["ready"] as? Bool == true { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready else { throw NSError(domain: "local fixture main page not loaded", code: 1) }
            let first = try await request("place")
            print("FIRST_FRAME_RESULT \(first)")
            try check(first["ok"] as? Bool == true && first["placeID"] as? String == "101", "iPhone-width cross-origin restaurant frame")
            try check(first["address"] as? String == "서울 중구 세종대로 1", "detail address arrives without WKFrameInfo")
            _ = try await evaluate("document.querySelector('#entryIframe').src='http://127.0.0.1:8349/place/102/home'; return JSON.stringify({ok:true});")
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
        let tests = FrameChecks()
        Task { await tests.run() }
        app.run()
    }
}
