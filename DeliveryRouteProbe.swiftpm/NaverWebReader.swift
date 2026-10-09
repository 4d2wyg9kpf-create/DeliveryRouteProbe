import Foundation
import WebKit

// All frame reads use a nonce and the current iframe window. WKFrameInfo is
// deliberately not retained: it can describe an old document after navigation.
@MainActor
enum NaverWebReader {
    static func configure(_ configuration: WKWebViewConfiguration) {
        let source = "(" + NaverFrameBridgeScript.source + ")(" + NaverPlaceDetailScript.source + "," + NaverSavedListScript.source + ");"
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    static func evaluate(_ view: WKWebView, _ body: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let raw: Any = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(with: result.map { $0 ?? NSNull() })
            }
        }
        try Task.checkCancellation()
        guard let string = raw as? String, let data = string.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlannerFailure.message("네이버 화면에서 읽은 결과를 확인하지 못했습니다.")
        }
        guard object["ok"] as? Bool == true else {
            throw PlannerFailure.message(object["message"] as? String ?? "네이버 화면을 읽지 못했습니다.")
        }
        return object
    }

    static func root(_ view: WKWebView) async throws -> [String: Any] {
        try await evaluate(view, "return (" + NaverPlaceRootScript.source + ")();")
    }

    static func frame(_ view: WKWebView, kind: String, command: String = "read", args: [String: Any] = [:]) async throws -> [String: Any] {
        try await evaluate(view, "return await (" + NaverFrameRequestScript.source + ")(kind, command, requestID, args);",
                           arguments: ["kind": kind, "command": command, "requestID": UUID().uuidString, "args": args])
    }

    static func panel(_ view: WKWebView, showMap: Bool) async throws {
        _ = try await evaluate(view, "return await (" + NaverMapPanelScript.source + ")(showMap);", arguments: ["showMap": showMap])
    }

    static func selected(_ view: WKWebView, resolveCoordinate: Bool = true) async throws -> NaverPlaceCapture {
        let before = try await root(view)
        let detail = before["kind"] as? String == "place" ? try await frame(view, kind: "place") : [:]
        let after = try await root(view)
        var value = try NaverPlaceBridge.call("merge", ["before": before, "after": after, "detail": detail,
                                                       "now": Date().timeIntervalSince1970 * 1000], as: NaverPlaceCapture.self)
        if resolveCoordinate && value.coordinate == nil {
            do { value = try await AddressGeocoder.shared.resolve(value) }
            catch is CancellationError { throw CancellationError() }
            catch {
                let addressIssue = error.localizedDescription
                if value.kind == "place" {
                    do {
                        let map = try await NaverPlaceLookup().read(placeID: value.placeID)
                        value = try NaverPlaceBridge.call("enrich", ["capture": try TMapBridge.object(value), "map": try TMapBridge.object(map)], as: NaverPlaceCapture.self)
                    } catch is CancellationError { throw CancellationError() }
                    catch { value.coordinateIssue = addressIssue + " " + error.localizedDescription }
                } else { value.coordinateIssue = addressIssue }
            }
            let current = try await root(view)
            guard current["selectionKey"] as? String == value.selectionKey else {
                throw PlannerFailure.message("좌표를 읽는 동안 선택 장소가 바뀌었습니다. 다시 읽어 주세요.")
            }
        }
        return value
    }
}

// A fixed-size PUBLIC place page supplies a laid-out map even when the phone's
// search panel covers its map. It uses the exact selected Naver POI ID, never an
// address approximation, private Naver endpoints, or the TMAP API.
@MainActor
final class NaverPlaceLookup {
    private let view: WKWebView
    init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.websiteDataStore = .nonPersistent()
        NaverWebReader.configure(configuration)
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
    }
    func read(placeID: String) async throws -> NaverPlaceCapture {
        guard placeID.range(of: "^\\d{1,30}$", options: .regularExpression) != nil,
              let url = URL(string: "https://map.naver.com/p/entry/place/\(placeID)?c=18.00,0,0,0,dh") else {
            throw PlannerFailure.message("좌표를 가져올 장소 식별자를 확인해 주세요.")
        }
        view.load(URLRequest(url: url))
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(28)
        var lastIssue = "장소 지도가 준비되지 않았습니다."
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let root = try await NaverWebReader.root(view)
                guard root["placeID"] as? String == placeID else { throw PlannerFailure.message("선택 장소의 지도 로딩을 기다리고 있습니다.") }
                if root["coordinate"] is [String: Any] {
                    let value = try await NaverWebReader.selected(view, resolveCoordinate: false)
                    if value.coordinate != nil { return value }
                }
                lastIssue = root["coordinateIssue"] as? String ?? lastIssue
            } catch is CancellationError { throw CancellationError() }
            catch { lastIssue = error.localizedDescription }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw PlannerFailure.message("선택 장소의 좌표를 가져오지 못했습니다. 네이버 지도를 새로고침한 뒤 다시 읽어 주세요. \(lastIssue)")
    }
}
