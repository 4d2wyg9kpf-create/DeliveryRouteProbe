import Foundation
import Combine
import WebKit
import SwiftUI

@MainActor
final class FacilityRouteWebRunner: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var message = "웹 경로를 자동으로 조회합니다."
    @Published private(set) var desktop = false
    private(set) var lastNavigationURL = ""
    private var activeID: String?
    private var navigationError: Error?
    private var upgradedNavigation = false
    private var allowedHosts = Set<String>()

    func query(_ request: FacilityRouteRequest) async throws -> [KakaoDistanceRecord] {
        try request.validate()
        guard activeID == nil else { throw PlannerFailure.message("웹 조회가 이미 진행 중입니다.") }
        try Task.checkCancellation()
        activeID = request.id; navigationError = nil; upgradedNavigation = false; desktop = request.transport == .car
        allowedHosts = request.provider == .naverWeb ? ["map.naver.com", "m.map.naver.com", "m.search.naver.com"] : ["map.kakao.com", "m.map.kakao.com"]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: desktop ? 1280 : 393, height: 700), configuration: configuration)
        // Desktop width alone does not select a desktop response on iPhone. Content mode and UA agree.
        view.customUserAgent = desktop ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" : "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = self; webView = view
        message = request.provider.title + " · " + request.transport.title + " 경로를 엽니다."
        view.load(URLRequest(url: request.webURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 45))
        defer { activeID = nil; view.stopLoading() }
        let deadline = ProcessInfo.processInfo.systemUptime + 150
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard activeID == request.id else { throw CancellationError() }
            if let navigationError { throw navigationError }
            if let url = view.url, url.scheme == "https", allowedHosts.contains(url.host ?? "") {
                do {
                    let raw = try await read(view, request: request)
                    guard let string = raw as? String, let data = string.data(using: .utf8), data.count <= 1_000_000 else { throw PlannerFailure.message("웹 요약 응답을 읽지 못했습니다.") }
                    let reply = try JSONDecoder().decode(FacilityWebReply.self, from: data)
                    if reply.status == "ready" { try Task.checkCancellation(); message = "출발·도착·이동방식과 결과를 확인했습니다."; return try FacilityRouteRecords.web(reply, request: request) }
                    if reply.status == "error" { throw PlannerFailure.message(reply.message ?? "웹 경로 검증에 실패했습니다.") }
                    message = reply.message ?? "웹 결과를 기다립니다."
                } catch let error as WKError where [.javaScriptInvalidFrameTarget, .webViewInvalidated].contains(error.code) {
                    message = "이동한 웹 문서를 다시 확인합니다."
                }
            }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        throw PlannerFailure.message("웹 경로를 150초 안에 확인하지 못했습니다. 결과는 저장하지 않았습니다. 웹 화면을 확인한 뒤 다시 조회하세요.")
    }
    private func read(_ view: WKWebView, request: FacilityRouteRequest) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !finished else { return }; finished = true
                continuation.resume(throwing: PlannerFailure.message("웹 문서의 응답이 멈췄습니다. 이 구간을 다시 조회하세요."))
            }
            view.callAsyncJavaScript(FacilityRouteWebScript.source + "\nreturn JSON.stringify(DeliveryFacilityWeb.step(request));", arguments: ["request": request.scriptArguments], in: nil, in: .page) { result in
                guard !finished else { return }; finished = true; continuation.resume(with: result)
            }
        }
    }
    func cancel() { activeID = nil; webView?.stopLoading(); message = "웹 조회를 중단했습니다." }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false { lastNavigationURL = url.absoluteString }
        if url.scheme == "http", allowedHosts.contains(url.host ?? ""), navigationAction.targetFrame?.isMainFrame != false,
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.scheme = "https"
            if let upgraded = parts.url {
                upgradedNavigation = true; decisionHandler(.cancel)
                webView.load(URLRequest(url: upgraded, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 45)); return
            }
        }
        guard ["https", "about"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false, url.scheme == "https", !allowedHosts.contains(url.host ?? "") {
            navigationError = PlannerFailure.message("길찾기 화면이 공식 지도 경로를 벗어나 중단했습니다."); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if !ignorableNavigationError(error) { navigationError = error } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if !ignorableNavigationError(error) { navigationError = error } }
    private func ignorableNavigationError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.code == NSURLErrorCancelled || (upgradedNavigation && e.domain == WKError.errorDomain && e.code == 102)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { navigationError = PlannerFailure.message("지도 웹 문서가 종료되었습니다. 이 구간을 다시 조회하세요.") }
}

#if canImport(UIKit)
import UIKit

private final class FacilityWebCanvas: UIScrollView {
    var routeView: WKWebView?
    var desktop = false
    func install(_ view: WKWebView?, desktop: Bool) {
        if routeView !== view { routeView?.removeFromSuperview(); routeView = view; if let view { addSubview(view) } }
        self.desktop = desktop; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = desktop ? max(1280, bounds.width) : bounds.width
        let height = desktop ? max(700, bounds.height) : bounds.height
        routeView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        contentSize = CGSize(width: width, height: height)
    }
}
struct FacilityRouteWebCanvas: UIViewRepresentable {
    let webView: WKWebView?
    let desktop: Bool
    func makeUIView(context: Context) -> UIScrollView {
        let canvas = FacilityWebCanvas(); canvas.backgroundColor = .secondarySystemBackground
        canvas.isDirectionalLockEnabled = true; canvas.accessibilityLabel = "길찾기 웹 화면"
        canvas.install(webView, desktop: desktop); return canvas
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) { (uiView as? FacilityWebCanvas)?.install(webView, desktop: desktop) }
}
#endif
