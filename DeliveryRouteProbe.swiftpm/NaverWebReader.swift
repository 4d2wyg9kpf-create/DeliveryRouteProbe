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
                continuation.resume(with: result)
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

    static func selected(_ view: WKWebView, resolveCoordinate: Bool = true, sharedURL: String? = nil) async throws -> NaverPlaceCapture {
        let before = try await root(view)
        let detail = before["kind"] as? String == "place" ? try await frame(view, kind: "place") : [:]
        let after = try await root(view)
        var value = try NaverPlaceBridge.call("merge", ["before": before, "after": after, "detail": detail,
                                                       "now": Date().timeIntervalSince1970 * 1000], as: NaverPlaceCapture.self)
        // An address chosen on the map denotes its selected pin, including on
        // retry or in a saved folder. Manual address geocoding is a separate mode.
        if let selectionURL = sharedURL ?? (value.kind == "address" ? view.url?.absoluteString : nil) {
            value = try NaverPlaceBridge.call("shared", ["capture": try TMapBridge.object(value), "url": selectionURL], as: NaverPlaceCapture.self)
        }
        if resolveCoordinate && value.coordinate == nil && !(value.kind == "address" && value.sharedLinkURL != nil) {
            do { value = try await NaverAPIStore.shared.resolve(value) }
            catch is CancellationError { throw CancellationError() }
            catch {
                value.coordinateIssue = error.localizedDescription
            }
            let current = try await root(view)
            guard current["selectionKey"] as? String == value.selectionKey else {
                throw PlannerFailure.message("좌표를 읽는 동안 선택 장소가 바뀌었습니다. 다시 읽어 주세요.")
            }
        }
        return value
    }
}
