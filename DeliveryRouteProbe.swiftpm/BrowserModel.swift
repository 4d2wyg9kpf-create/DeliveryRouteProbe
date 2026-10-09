import Foundation
import WebKit
import Combine
import UIKit

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    private var storedWebView: WKWebView?
    var webView: WKWebView {
        if let view = storedWebView { return view }
        let view = makeWebView()
        storedWebView = view
        return view
    }
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var isReading = false
    @Published var isReadingBike = false
    @Published var isReadingPlace = false
    @Published var placeCapture: NaverPlaceCapture?
    private var placeFrame: WKFrameInfo?
    private var placeReadID: UUID?
    @Published var bikeCapture: BikeEntranceCapture?
    private var bikeReadID: UUID?
    @Published var status = "예제 경로 또는 네이버 지도에서 자동차 길찾기를 열어 주세요."
    @Published var errorMessage: String?
    @Published var capture: RouteCapture?
    @Published var exportData: Data?

    private var observations: [NSKeyValueObservation] = []
    @Published private(set) var currentPageAddress: String = ""
    private var hasLoaded = false

    // Public example opened and inspected during the integration test.
    static let sampleURL = "https://map.naver.com/p/directions/3zANVL,2zWgoY,%EB%8C%80%EC%A0%84%EC%97%AD%20(%EA%B3%A0%EC%86%8D%EC%B2%A0%EB%8F%84),13479709,PLACE_POI/3zyNL6,2zX0KV,%EB%8C%80%EC%A0%84%EA%B4%91%EC%97%AD%EC%8B%9C%EC%B2%AD%EB%8F%99%EB%AC%B8,16290487,PLACE_POI/-/car?c=13.00,0,0,0,dh"

    override init() {
        super.init()
        restoreLastCapture()
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(NaverPlaceFrameHandler(owner: self), name: "deliveryNaverPlaceFrame")
        configuration.userContentController.addUserScript(WKUserScript(source: #"if (location.protocol === 'https:' && location.hostname === 'pcmap.place.naver.com') { window.webkit.messageHandlers.deliveryNaverPlaceFrame.postMessage('ready'); }"#, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive

        observations.append(webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
        })
        observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.isLoading = view.isLoading }
        })
        observations.append(webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.progress = view.estimatedProgress }
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.currentPageAddress = view.url?.absoluteString ?? ""
                if let bike = self.bikeCapture, RoadBridge.bikeKey(self.currentPageAddress) != bike.routeKey {
                    self.bikeCapture = nil
                }
            }
        })
        return webView
    }

    func endMapEditingIfLoaded() { storedWebView?.endEditing(true) }

    func startIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        openSample()
    }

    func openHome() { open("https://map.naver.com/") }
    func openSample() { open(Self.sampleURL) }

    func openRecordedRoute(_ value: String) {
        guard let url = URL(string: value), url.scheme == "https", url.host == "map.naver.com" else {
            errorMessage = "저장한 네이버 지도 주소를 확인해 주세요."
            return
        }
        open(value)
    }

    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        hasLoaded = true
        errorMessage = nil
        bikeReadID = nil
        isReadingBike = false
        bikeCapture = nil
        placeCapture = nil
        webView.load(URLRequest(url: url))
    }

    fileprivate func rememberPlaceFrame(_ frame: WKFrameInfo) {
        guard !frame.isMainFrame, frame.securityOrigin.host == "pcmap.place.naver.com",
              frame.request.url?.scheme == "https", frame.request.url?.path.hasPrefix("/place/") == true else { return }
        placeFrame = frame
    }

    private func evaluatePlaceScript(_ source: String, frame: WKFrameInfo? = nil,
                                     completion: @escaping (Result<[String: Any], Error>) -> Void) {
        webView.callAsyncJavaScript("return (" + source + ")();", arguments: [:], in: frame, in: .page) { outcome in
            DispatchQueue.main.async {
                do {
                    let raw = try outcome.get()
                    guard let text = raw as? String, let data = text.data(using: .utf8),
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw PlannerFailure.message("네이버 장소 정보를 읽지 못했습니다.")
                    }
                    guard object["ok"] as? Bool == true else {
                        throw PlannerFailure.message(object["message"] as? String ?? "검색 결과의 장소를 하나 선택하고 다시 읽어 주세요.")
                    }
                    completion(.success(object))
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func loadSelectedPlace(completion: @escaping (Result<NaverPlaceCapture, Error>) -> Void) {
        guard !webView.isLoading, webView.url?.scheme == "https", webView.url?.host == "map.naver.com" else {
            completion(.failure(PlannerFailure.message("네이버 지도에서 검색·저장 장소나 주소를 선택한 뒤 읽어 주세요."))); return
        }
        evaluatePlaceScript(NaverPlaceRootScript.source) { [weak self] beforeResult in
            guard let self = self else { return }
            do {
                let before = try beforeResult.get()
                let finish: ([String: Any]) -> Void = { [weak self] detail in
                    guard let self = self else { return }
                    self.evaluatePlaceScript(NaverPlaceRootScript.source) { afterResult in
                        do {
                            let after = try afterResult.get()
                            let value = try NaverPlaceBridge.call("merge", ["before": before, "after": after, "detail": detail,
                                                                          "now": Date().timeIntervalSince1970 * 1000], as: NaverPlaceCapture.self)
                            completion(.success(value))
                        } catch { completion(.failure(error)) }
                    }
                }
                if before["kind"] as? String == "place" {
                    guard let frame = self.placeFrame else {
                        throw PlannerFailure.message("장소 상세 패널이 준비되지 않았습니다. 상세 화면이 열린 뒤 다시 읽어 주세요.")
                    }
                    self.evaluatePlaceScript(NaverPlaceDetailScript.source, frame: frame) { result in
                        do { finish(try result.get()) } catch { completion(.failure(error)) }
                    }
                } else { finish([:]) }
            } catch { completion(.failure(error)) }
        }
    }

    func readSelectedPlace() {
        guard !isReading, !isReadingBike, !isReadingPlace else { return }
        let readID = UUID(); placeReadID = readID
        isReadingPlace = true; errorMessage = nil; placeCapture = nil
        status = "선택한 네이버 장소의 좌표·주소를 읽고 있습니다."
        loadSelectedPlace { [weak self] result in
            guard let self = self, self.placeReadID == readID else { return }
            self.isReadingPlace = false; self.placeReadID = nil
            do {
                let value = try result.get(); self.placeCapture = value
                self.status = value.coordinate != nil ? "선택 장소의 좌표·주소를 읽었습니다. 거래처와 연결해 주세요." : "선택 장소의 주소를 읽었습니다. 좌표 확인 사항을 표시했습니다."
            } catch { self.errorMessage = error.localizedDescription; self.status = "장소를 연결하지 않았습니다." }
        }
    }

    func verifySelectedPlace(_ candidate: NaverPlaceCapture, useCoordinate: Bool, completion: @escaping (Bool) -> Void) {
        guard !isReading, !isReadingBike, !isReadingPlace else { completion(false); return }
        let readID = UUID(); placeReadID = readID; isReadingPlace = true
        loadSelectedPlace { [weak self] result in
            guard let self = self, self.placeReadID == readID else { completion(false); return }
            self.isReadingPlace = false; self.placeReadID = nil
            do {
                let fresh = try result.get()
                let check = try NaverPlaceBridge.call("sameSelection", ["capture": try TMapBridge.object(candidate), "fresh": try TMapBridge.object(fresh), "useCoordinate": useCoordinate], as: NaverPlaceSelectionCheck.self)
                if !check.same { self.placeCapture = fresh }
                completion(check.same)
            } catch { self.errorMessage = error.localizedDescription; completion(false) }
        }
    }

    func readBikeEndpoint() {
        guard !isReading, !isReadingBike, !isReadingPlace else { return }
        guard !webView.isLoading, let address = webView.url?.absoluteString,
              let key = RoadBridge.bikeKey(address) else {
            errorMessage = "네이버에서 경유지 없는 자전거 길찾기 결과를 열어 주세요."
            return
        }
        let requestID = UUID()
        bikeReadID = requestID
        bikeCapture = nil
        placeCapture = nil
        errorMessage = nil
        isReadingBike = true
        status = "자전거 상세 안내를 열고 도착 위치를 확대하고 있습니다."
        webView.callAsyncJavaScript("return await (" + PrepareBikeEndpointScript.source + ")(reader);",
                                    arguments: ["reader": BikeEndpointScript.source], in: nil, in: .page) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self, self.bikeReadID == requestID else { return }
                self.bikeReadID = nil
                self.isReadingBike = false
                do {
                    let raw = try outcome.get()
                    guard let json = raw as? String, let data = json.data(using: .utf8) else {
                        throw PlannerFailure.message("자전거 종점 정보를 읽지 못했습니다.")
                    }
                    let capture = try JSONDecoder().decode(BikeEntranceCapture.self, from: data)
                    let current = self.webView.url?.absoluteString ?? ""
                    guard RoadBridge.bikeKey(current) == key, capture.routeKey == key else {
                        throw PlannerFailure.message("읽는 동안 자전거 목적지가 바뀌었습니다. 다시 읽어 주세요.")
                    }
                    self.currentPageAddress = current
                    self.bikeCapture = capture
                    self.status = "자전거 종점 후보를 읽었습니다. 배송계획의 거래처에서 입구와 하역 위치를 연결해 주세요."
                } catch {
                    self.errorMessage = "자전거 종점을 저장하지 못했습니다: \(error.localizedDescription)"
                    self.status = "입구 후보를 저장하지 않았습니다."
                }
            }
        }
    }

    func verifyBikeCapture(_ candidate: BikeEntranceCapture, completion: @escaping (Bool) -> Void) {
        guard !isReading, !isReadingBike, !isReadingPlace, !webView.isLoading,
              bikeCapture?.point.token == candidate.point.token else { completion(false); return }
        // A typed-but-unsubmitted place changes the input without changing URL.
        // Read current visible controls again before attaching a saved candidate.
        webView.callAsyncJavaScript("return (" + BikeEndpointScript.source + ")(true);",
                                    arguments: [:], in: nil, in: .page) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self, self.bikeCapture?.point.token == candidate.point.token,
                      RoadBridge.bikeKey(self.webView.url?.absoluteString ?? "") == candidate.routeKey,
                      case .success(let value) = outcome, let text = value as? String,
                      let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["ok"] as? Bool == true,
                      object["routeKey"] as? String == candidate.routeKey,
                      object["selection"] as? String == candidate.detailSummary,
                      object["selectedIndex"] as? Int == candidate.selectedIndex else {
                    completion(false); return
                }
                completion(true)
            }
        }
    }

    func readScreen() {
        guard !isReading, !isReadingBike, !isReadingPlace else { return }
        placeCapture = nil
        guard let page = webView.url, page.scheme == "https", page.host == "map.naver.com" else {
            errorMessage = "네이버 지도 화면에서 읽어 주세요."
            return
        }
        guard !webView.isLoading else {
            errorMessage = "지도 화면이 열린 뒤 다시 읽어 주세요."
            return
        }
        // Keep the reader in Swift source so Playgrounds does not need a
        // generated resource-bundle accessor or a separately copied JS file.
        let script = RouteCaptureScript.source
        let sourceURL = page.absoluteString
        isReading = true
        errorMessage = nil
        status = "화면의 경로 정보를 읽는 중입니다."
        webView.callAsyncJavaScript("return await (" + PeekVehicleScript.source + ")(reader, profile);",
                                    arguments: ["reader": script, "profile": VehicleProfileScript.source],
                                    in: nil, in: .page) { [weak self] outcome in
            let value: Any?
            let error: Error?
            switch outcome {
            case .success(let result): value = result; error = nil
            case .failure(let failure): value = nil; error = failure
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isReading = false
                if let error = error {
                    self.errorMessage = "화면을 읽지 못했습니다: \(error.localizedDescription)"
                    return
                }
                guard self.webView.url?.absoluteString == sourceURL else {
                    self.errorMessage = "읽는 동안 지도 화면이 바뀌었습니다. 다시 읽어 주세요."
                    return
                }
                guard let json = value as? String, let data = json.data(using: .utf8) else {
                    self.errorMessage = "지도에서 예상한 형식의 결과가 반환되지 않았습니다."
                    return
                }
                do {
                    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    object["pageURL"] = sourceURL
                    object["capturedAt"] = ISO8601DateFormatter().string(from: Date())
                    let savedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    let decoded = try JSONDecoder().decode(RouteCapture.self, from: savedData)
                    self.capture = decoded
                    self.exportData = savedData
                    self.status = decoded.quality.readyForSummaryImport
                        ? "경로 요약을 읽었습니다. 아래는 마지막으로 읽은 정보입니다."
                        : "화면을 읽었습니다. 확인할 항목을 아래에 표시합니다."
                    do {
                        try savedData.write(to: self.captureFileURL(), options: .atomic)
                    } catch {
                        self.errorMessage = "정보는 읽었지만 기기 저장에 실패했습니다. 기록 내보내기를 이용해 주세요."
                    }
                } catch {
                    self.errorMessage = "경로 정보를 해석하지 못했습니다: \(error.localizedDescription)"
                }
            }
        }
    }

    private func captureFileURL() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("RouteProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("latest-route.json")
    }

    private func restoreLastCapture() {
        do {
            let data = try Data(contentsOf: captureFileURL())
            capture = try JSONDecoder().decode(RouteCapture.self, from: data)
            exportData = data
            status = "지난번에 읽은 기록을 불러왔습니다. 현재 경로는 화면 읽기로 갱신해 주세요."
        } catch { /* The first launch normally has no saved capture. */ }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
        placeCapture = nil
        placeFrame = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            errorMessage = "지도를 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let scheme = action.request.url?.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if ["https", "http", "about"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            errorMessage = "외부 앱으로 연결되는 링크입니다. 이번 검증은 웹 지도에서 진행해 주세요."
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    private func presenter() -> UIViewController? {
        var result = webView.window?.rootViewController
        while let presented = result?.presentedViewController { result = presented }
        return result
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = presenter() else { completionHandler(); return }
        let alert = UIAlertController(title: "지도 메시지", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = presenter() else { completionHandler(false); return }
        let alert = UIAlertController(title: "지도 확인", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }
}

private final class NaverPlaceFrameHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserModel?
    init(owner: BrowserModel) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        DispatchQueue.main.async { [weak self] in self?.owner?.rememberPlaceFrame(frame) }
    }
}

// BEGIN EMBEDDED ROUTE CAPTURE SCRIPT
// Generated by scripts/embed_capture_script.py. Keep JavaScript escapes literal.
private enum RouteCaptureScript {
    static let source = #"""
    () => {
      // Read only the rendered map UI. No requests, private app state, or DOM writes.
      const tidy = value => String(value || "").replace(/\s+/g, " ").trim();
      const shown = element => {
        if (!element || !element.getClientRects().length) return false;
        const style = getComputedStyle(element);
        return style.display !== "none" && style.visibility !== "hidden";
      };
      const text = element => element ? tidy(element.innerText || element.textContent) : "";
      const all = (root, selector) => Array.from(root.querySelectorAll(selector));
      const distance = raw => {
        const match = tidy(raw).match(/^([\d,]+(?:\.\d+)?)\s*(km|m)$/i);
        return match ? Math.round(Number(match[1].replace(/,/g, "")) * (match[2].toLowerCase() === "km" ? 1000 : 1)) : null;
      };
      const minutes = raw => {
        const value = tidy(raw);
        if (!value || !/^(?:\d+\s*일\s*)?(?:\d+\s*시간\s*)?(?:\d+\s*분\s*)?(?:\d+\s*초\s*)?$/.test(value)) return null;
        const days = Number(value.match(/(\d+)\s*일/)?.[1] || 0);
        const hours = Number(value.match(/(\d+)\s*시간/)?.[1] || 0);
        const mins = Number(value.match(/(\d+)\s*분/)?.[1] || 0);
        const seconds = Number(value.match(/(\d+)\s*초/)?.[1] || 0);
        return days * 1440 + hours * 60 + mins + seconds / 60;
      };
      const money = raw => {
        if (/^통행료\s*무료$/.test(tidy(raw))) return 0;
        const match = tidy(raw).match(/^통행료\s*([\d,]+)\s*원$/);
        return match ? Number(match[1].replace(/,/g, "")) : null;
      };
      const panel = all(document, '[role="tabpanel"]').find(shown);
      const mode = text(all(document, '[role="tab"][aria-selected="true"]').find(el => /^(자동차|자전거|도보|대중교통)$/.test(text(el))));
      const inputPoints = all(document, 'input[role="combobox"]').filter(shown).map(input => ({
        label: tidy(Array.from(input.labels || []).map(label => text(label)).join(" ")),
        value: input.value || ""
      }));
      const summaryPoints = panel ? all(panel, '.direction_list .direction_text').map(text) : [];
      const cards = panel ? all(panel, '[role="button"][aria-pressed]').filter(el => shown(el) && el.querySelector('.route_summary_box')) : [];
      const candidates = cards.map(card => {
        const durationText = text(card.querySelector('.route_summary_info_duration strong'));
        const distanceText = text(card.querySelector('.route_summary_info_duration .item_distance'));
        const tollText = all(card, '.route_summary_info_list li').map(text).find(t => /^통행료/.test(t)) || "";
        const sections = all(card, 'ol li').map(row => {
          const congestion = text(row.querySelector('.item_icon'));
          const distanceText = text(row.querySelector('.item_distance'));
          // The road name is the row's rendered direct text, excluding the two spans.
          const road = tidy(Array.from(row.childNodes).filter(node => node.nodeType === 3).map(node => node.textContent).join(" "));
          return { road, congestion, distanceText, distanceMeters: distance(distanceText) };
        });
        return {
          index: Number(text(card.querySelector('.summary_label_badge'))) || null,
          label: text(card.querySelector('.summary_label_text')),
          selected: card.getAttribute('aria-pressed') === 'true',
          durationText, durationMinutes: minutes(durationText),
          distanceText, distanceMeters: distance(distanceText),
          tollText, tollWon: money(tollText), sections
        };
      });
      const selectedCandidates = candidates.filter(candidate => candidate.selected);
      const selected = selectedCandidates.length === 1 ? selectedCandidates[0] : null;
      const detailPanel = document.getElementById('sub_panel');
      const detailVisible = shown(detailPanel);
      const detailIndex = detailVisible ? Number(text(detailPanel.querySelector('.summary_label_badge'))) || null : null;
      const detailLabel = detailVisible ? text(detailPanel.querySelector('.summary_label_text')) : "";
      const detailDuration = detailVisible ? text(detailPanel.querySelector('.route_summary_info_duration strong')) : "";
      const detailDistance = detailVisible ? text(detailPanel.querySelector('.route_summary_info_duration .item_distance')) : "";
      const detailMatchesSelected = Boolean(selected && detailVisible && selected.index === detailIndex && selected.label === detailLabel && selected.durationText === detailDuration && selected.distanceText === detailDistance);
      const guides = detailMatchesSelected ? all(detailPanel, '.directions_detail_list > li').map(row => {
        const instruction = text(row.querySelector('.guide_info_route'));
        const icon = row.querySelector('.guide_info_icon img, .guide_item_icon img');
        const distanceText = text(row.querySelector('.guide_info_icon'));
        return { type: icon?.getAttribute('alt') || "", instruction, distanceText, distanceMeters: distance(distanceText) };
      }) : [];
      const arrivalSideText = detailMatchesSelected ? text(detailPanel.querySelector('.destination_panorama_text')) : "";
      const arrivalSide = /오른쪽/.test(arrivalSideText) ? 'right' : /왼쪽/.test(arrivalSideText) ? 'left' : /전방|앞쪽/.test(arrivalSideText) ? 'ahead' : null;
      const vehicleSummary = panel ? all(panel, 'button').map(text).find(t => /차량 기준$/.test(t)) || "" : "";
      const vehicleClass = vehicleSummary.match(/^(\d)종(?:\(경차\))?/)?.[0] || null;
      const dialogs = all(document, 'dialog, [role="dialog"]').filter(shown);
      const settings = dialogs.find(el => text(el).includes('차종/연료 설정'));
      const forecast = dialogs.find(el => text(el).includes('나중에 출발'));
      const settingsDraft = settings ? {
        note: "설정창의 현재 선택이며 저장·경로 반영을 확인한 값이 아닙니다.",
        checkedLabels: all(settings, 'input[type="checkbox"]').filter(el => el.checked).map(el => text(el.parentElement)),
        selectedPresets: all(settings, 'button.option_button.on').map(text),
        customValues: all(settings, 'input[type="text"]').filter(el => el.value).map(el => ({
          context: text(el.parentElement?.parentElement), value: el.value
        }))
      } : null;
      // With intermediate points the main summary lists only the two endpoints.
      // Bind all points to the selected detail's visible departure/via/arrival rows.
      const detailPoints = guides.filter(g => /^(출발지|도착지|경유지\d+)$/.test(g.type)).map(g => tidy(g.instruction));
      const routePoints = inputPoints.length > 2 ? detailPoints : summaryPoints;
      const summaryMatches = summaryPoints.length === 2 && routePoints.length >= 2 && summaryPoints[0] === routePoints[0] && summaryPoints[1] === routePoints[routePoints.length-1];
      const inputNames = inputPoints.map(point => tidy(point.value)).filter(Boolean);
      const inputMatchesRoute = summaryMatches && routePoints.length >= 2 && inputNames.length === routePoints.length && inputNames.every((name, i) => name === tidy(routePoints[i]));
      const searchOpen = all(document, '[role="listbox"]').some(shown);
      const issues = [];
      if (mode !== '자동차') issues.push('자동차 길찾기 화면에서 읽어 주세요.');
      if (!candidates.length) issues.push('자동차 경로 결과가 아직 없거나 화면 구조가 달라졌습니다.');
      if (candidates.length && !selected) issues.push('선택된 경로를 하나로 확인할 수 없습니다.');
      if (candidates.length && !inputMatchesRoute) issues.push('입력 중인 장소와 계산된 경로의 장소가 일치하지 않습니다.');
      if (searchOpen) issues.push('장소 검색·선택을 마친 뒤 다시 읽어 주세요.');
      if (settings) issues.push('차량 설정창의 선택은 아직 경로에 반영되지 않았을 수 있습니다.');
      if (dialogs.length && !settings) issues.push('열린 안내창을 닫은 뒤 경로를 다시 읽어 주세요.');
      if (detailVisible && !detailMatchesSelected) issues.push('상세 안내가 선택된 경로와 일치하지 않습니다.');
      if (selected && (selected.durationMinutes === null || selected.distanceMeters === null)) issues.push('선택된 경로의 시간 또는 거리를 해석하지 못했습니다.');
      const readyForSummaryImport = mode === '자동차' && Boolean(selected) && inputMatchesRoute && !searchOpen && !dialogs.length && selected.durationMinutes !== null && selected.distanceMeters !== null;
      return JSON.stringify({
        schemaVersion: 1, extractorVersion: '0.5.0', mode, inputPoints, routePoints,
        vehicleSummary, vehicleClass, settingsDraft,
        departureForecastText: forecast ? text(forecast) : null,
        departureTimeLabel: panel ? text(panel.querySelector('.later_departure_btn_text')) : "",
        sourceTimeText: text(all(document, '.time_info_text').find(shown)),
        candidates, detail: { visible: detailVisible, routeIndex: detailIndex, matchesSelected: detailMatchesSelected, guides, arrivalSide, arrivalSideText },
        quality: {
          inputMatchesRoute, readyForSummaryImport,
          departureDirectionVerified: false, arrivalCurbVerified: false,
          heightClearanceVerified: false, class1FareForHeightRouteVerified: false,
          fullRoadGeometryAvailable: false, routeLockVerified: false,
          trafficFreshnessVerified: false,
          issues
        }
      });
    }
    """#
}
// END EMBEDDED ROUTE CAPTURE SCRIPT
