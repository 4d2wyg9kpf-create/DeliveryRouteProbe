import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum DeliveryAppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발"
    }
}

@main
@MainActor
struct DeliveryRouteProbeApp: App {
    var body: some Scene {
        WindowGroup { DeliveryRootView() }
    }
}

// Like M4Download's UnifiedDownloadView, own app state in the root view.
@MainActor
struct DeliveryRootView: View {
    @StateObject private var model = BrowserModel()
    @StateObject private var planner = PlannerStore()
    @StateObject private var customers = NaverCustomerStore()
    @StateObject private var tmap = TMapStore.shared
    @StateObject private var trip = TripStore.shared
    @StateObject private var inputs = NativeInputSession()
    @State private var selectedTab = 3
    @State private var showNaverWeb = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $selectedTab) {
            TMapScreen(store: tmap, planner: planner, browser: model) { url in
                openNaver(url)
            }
                .tabItem { Label("티맵 최적화", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.tag(3)
            Group {
                // Do not construct/attach a web view behind the planner.
                if selectedTab == 0 { NaverSearchScreen(planner: planner, browser: model, showWeb: $showNaverWeb) }
                else { Color.clear }
            }
            .disabled(selectedTab != 0)
            .tabItem { Label("네이버 검색", systemImage: "magnifyingglass") }.tag(0)
            PlannerScreen(store: planner, browser: model) { url in
                openNaver(url)
            }
            .disabled(selectedTab != 1)
            .tabItem { Label("배송계획", systemImage: "list.number") }.tag(1)
            TripScreen(store: trip, planner: planner, browser: model) { url in
                openNaver(url)
            }
            .disabled(selectedTab != 2)
            .tabItem { Label("운행 안내", systemImage: "truck.box") }.tag(2)
        }
        .environmentObject(inputs)
        .environmentObject(customers)
        .onAppear {
            do { try customers.remember(planner.plan) }
            catch { customers.errorMessage = error.localizedDescription }
        }
        .onAppear { InputDiagnostics.shared.start() }
        .onChange(of: selectedTab) { _, _ in inputs.finishEditing() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { planner.saveNow() }
            else { Task { await tmap.refreshClock() } }
        }
    }
    private func openNaver(_ url: String) {
        inputs.finishEditing()
        if url.contains("/favorite") { model.openSavedLists(customers); showNaverWeb = true }
        else if ["https://map.naver.com/", "https://map.naver.com/p/"].contains(url) { showNaverWeb = false }
        else { model.openRecordedRoute(url); showNaverWeb = true }
        selectedTab = 0
    }
}

struct MapWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

struct ProbeView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var planner: PlannerStore
    @State private var showExport = false
    @State private var exportDocument = CaptureDocument()
    @State private var mapExpanded = UIDevice.current.userInterfaceIdiom == .phone
    @State private var showCustomers = false
    @State private var showSharedLink = false
    @EnvironmentObject private var customers: NaverCustomerStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("지도 보기") { mapExpanded = true; model.showMapPanel(true) }
                Button("검색·장소") { mapExpanded = true; model.showMapPanel(false) }
                Spacer()
                Button("이번 배송 선택") { showCustomers = true }
            }.buttonStyle(.bordered).font(.subheadline).padding(.horizontal, 12).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button { _ = model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canGoBack).accessibilityLabel("뒤로")
                    Button { _ = model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.canGoForward).accessibilityLabel("앞으로")
                    Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("새로고침")
                    Button("지도 홈", action: model.openHome)
                    Button("공유 링크 붙여넣기") { showSharedLink = true }
                        .disabled(model.isImportingSavedList || model.isReadingPlace || model.isOpeningSharedLink)
                    Button("저장 목록 전체 가져오기") { mapExpanded = true; model.openSavedLists(customers) }
                    Button(model.isReadingPlace ? "장소 읽는 중" : "선택 장소 읽기", action: model.readSelectedPlace)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isReading || model.isReadingBike || model.isReadingPlace || model.isImportingSavedList || model.isLoading)
                    Button("예제 경로", action: model.openSample)
                    Button(action: model.readScreen) {
                        Label(model.isReading ? "읽는 중" : "화면 읽기", systemImage: "doc.text.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isReading || model.isReadingBike || model.isReadingPlace || model.isImportingSavedList || model.isLoading)
                    Button(model.isReadingBike ? "종점 읽는 중" : "자전거 종점 읽기") {
                        mapExpanded = true
                        // Give the full-width map one layout pass before DOM reading.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.readBikeEndpoint() }
                    }.disabled(model.isReading || model.isReadingBike || model.isReadingPlace || model.isImportingSavedList || model.isLoading)
                    Button(mapExpanded ? "읽은 정보" : "지도 넓게") { mapExpanded.toggle() }
                        .disabled(model.isReadingBike)
                    Button("기록 내보내기") {
                        let data: Data?
                        if let place = model.placeCapture { data = try? JSONEncoder().encode(place) }
                        else if let bike = model.bikeCapture { data = try? JSONEncoder().encode(bike) }
                        else { data = model.exportData }
                        guard let data = data else { return }
                        exportDocument = CaptureDocument(data: data)
                        showExport = true
                    }.disabled(model.exportData == nil && model.bikeCapture == nil && model.placeCapture == nil)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            if model.isImportingSavedList || model.waitingForSavedFolder || !model.savedListProgress.isEmpty {
                NaverSavedListStatusView(browser: model) { showCustomers = true }
            }
            if model.isLoading { ProgressView(value: model.progress).progressViewStyle(.linear) }
            if mapExpanded {
                HStack {
                    if model.isReadingBike || model.isReadingPlace { ProgressView() }
                    Text(model.status).font(.caption)
                    if model.bikeCapture != nil { Button("종점 정보") { mapExpanded = false } }
                    if model.placeCapture != nil { Button("장소 정보") { mapExpanded = false } }
                }.padding(8)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Divider()
            GeometryReader { geometry in
                if mapExpanded {
                    MapWebView(webView: model.webView)
                } else if geometry.size.width >= 950 {
                    HStack(spacing: 0) {
                        MapWebView(webView: model.webView)
                        Divider()
                        CapturePanel(model: model, planner: planner).frame(width: 340)
                    }
                } else {
                    VStack(spacing: 0) {
                        MapWebView(webView: model.webView)
                        Divider()
                        CapturePanel(model: model, planner: planner).frame(height: min(300, geometry.size.height * 0.38))
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { model.startIfNeeded() }
        .sheet(isPresented: $showCustomers) { NaverCustomerCatalogView(planner: planner, browser: model) }
        .sheet(isPresented: $showSharedLink) {
            NaverSharedLinkView { text in
                try model.openSharedLink(text, customers: customers)
                mapExpanded = true
            }
        }
        .onChange(of: model.placeCapture?.selectionKey) { _, key in if key != nil { mapExpanded = false } }
        .onDisappear { model.endMapEditingIfLoaded() }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json, defaultFilename: "배송경로_확인기록") { result in
            if case .failure(let error) = result { model.errorMessage = "내보내기 실패: \(error.localizedDescription)" }
        }
    }
}

struct NaverSharedLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    let open: (String) throws -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("네이버 지도 공유 링크") {
                    Text("네이버 지도에서 장소나 저장 목록의 ‘공유 → 링크 복사’를 누른 뒤 여기에 붙여넣으세요.").font(.subheadline)
                    TextEditor(text: $text).frame(minHeight: 120).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("복사한 링크 붙여넣기") { text = UIPasteboard.general.string ?? ""; error = nil }
                    if let error { Text(error).foregroundColor(.red).font(.caption) }
                    Button("링크로 가져오기") {
                        do { try open(text); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section {
                    Text("장소 링크는 해당 장소를 열고 주소·좌표를 읽습니다. 확인한 장소 정보에서 거래처로 저장하세요. 저장 목록 링크는 접근 가능한 폴더의 장소를 모두 거래처 목록에 저장합니다.").font(.caption)
                    Text("지도 중심 좌표는 장소 좌표로 사용하지 않습니다. 저장 목록은 네이버의 공유 설정과 로그인 상태에 따라 접근할 수 있습니다.").font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("공유 링크 가져오기").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
    }
}

struct CapturePanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var planner: PlannerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("배송경로 \(DeliveryAppInfo.version) · 네이버 장소 연결").font(.headline)
                Text(model.status).font(.subheadline).foregroundColor(.secondary)
                if let place = model.placeCapture { NaverPlaceReadPanel(capture: place, planner: planner, browser: model) }
                if let bike = model.bikeCapture {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("자전거 종점 · 입구 후보", systemImage: "bicycle").font(.headline)
                        Text(bike.destination.name).bold()
                        if !bike.arrivalSideText.isEmpty { Text(bike.arrivalSideText).font(.caption) }
                        Text("목적지 표시와 경로 끝점의 차이: 약 \(bike.destinationGapMeters, specifier: "%.1f")m").font(.caption)
                        Text("화면 판독 해상도: 약 \(bike.screenResolutionMeters, specifier: "%.1f")m. 실제 지도 위치의 정확도를 뜻하지 않습니다.").font(.caption2).foregroundColor(.secondary)
                        Text("배송계획 → 하역·도로 → 해당 거래처 → 읽은 자전거 종점 가져오기를 선택하세요. 실제 입구와 차량 정차 위치는 확인 후 연결합니다.").font(.caption)
                        Text("다른 목적지로 바꾸면 이 임시 후보는 지워집니다.").font(.caption2).foregroundColor(.secondary)
                    }.padding(10).background(Color.green.opacity(0.1)).cornerRadius(8)
                }
                if let capture = model.capture {
                    if let when = capture.capturedAt { Text("마지막 읽기: \(when)").font(.caption2).foregroundColor(.secondary) }
                    if let time = capture.sourceTimeText, !time.isEmpty {
                        Text("지도에 표시된 시각: \(time)").font(.caption2).foregroundColor(.secondary)
                    }
                    Text("읽은 시각과 경로가 계산된 시각은 다를 수 있습니다.")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(capture.routePoints.joined(separator: " → ")).font(.subheadline).bold()
                    if let settings = capture.observedVehicleSettings, settings.confirmed, let height = settings.heightMM {
                        Text("저장된 지도 높이 설정: \(height)mm").font(.caption)
                    }
                    Text(capture.vehicleSummary.isEmpty ? "차종 미확인" : capture.vehicleSummary).font(.caption)

                    if !capture.quality.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(capture.quality.issues.enumerated()), id: \.offset) { _, issue in
                                Text("• \(issue)").font(.caption)
                            }
                        }.padding(10).background(Color.orange.opacity(0.12)).cornerRadius(8)
                    }

                    ForEach(Array(capture.candidates.enumerated()), id: \.offset) { _, route in
                        routeCard(route, vehicleClass: capture.vehicleClass)
                    }

                    Divider()
                    Text("선택한 경로의 도착 방향").font(.subheadline).bold()
                    Text(capture.detail.arrivalSideText.isEmpty
                         ? "네이버 지도에서 선택한 경로의 ‘상세보기’를 열고 다시 읽어 주세요."
                         : capture.detail.arrivalSideText)
                        .font(.subheadline)
                    Text("이 문구는 네이버의 도착지 기준입니다. 실제 하역 위치와 일치하는지 확인이 필요합니다.")
                        .font(.caption).foregroundColor(.secondary)

                    if !capture.detail.guides.isEmpty {
                        Text("상세 안내").font(.subheadline).bold()
                        ForEach(Array(capture.detail.guides.enumerated()), id: \.offset) { _, step in
                            VStack(alignment: .leading, spacing: 3) {
                                Text([step.type, step.distanceText].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundColor(.secondary)
                                Text(step.instruction).font(.subheadline)
                            }
                            Divider()
                        }
                    }

                    if let forecast = capture.departureForecastText {
                        Text("출발 시각별 예상 화면").font(.subheadline).bold()
                        Text(forecast).font(.caption)
                        Text("예상 화면의 시간을 위 경로의 이동시간으로 합치지 않았습니다.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else if model.placeCapture == nil && model.bikeCapture == nil {
                    Text("거래처 등록: 검색·저장 목록에서 장소의 상세 화면을 연 뒤 ‘선택 장소 읽기’를 누르세요. 장소 이름과 주소를 읽고 배송계획에 연결할 수 있습니다.")
                        .font(.subheadline)
                    Text("지도 핀이 가려져 있어도 읽은 주소를 네이버 API로 좌표 변환합니다. API 키를 설정하면 지도 표시 없이 좌표를 가져올 수 있습니다.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("경로 읽기: 자동차 길찾기의 ‘상세보기’를 연 뒤 ‘화면 읽기’를 누르세요.")
                        .font(.subheadline)
                    Text("높이 입력은 네이버의 ‘차량 기준’ 설정에서 2~5종을 선택하면 확인할 수 있습니다.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Divider()
                Text("배송계획에 연결하기")
                    .font(.subheadline).bold()
                Text("‘배송계획 → 하역·도로’에서 실제 하역 위치와 도로 유형을 등록하고 읽은 경로를 연결합니다. 회사 복귀까지 최대 30곳의 시간·적재·등록한 도로 조건을 함께 계산합니다.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func routeCard(_ route: RouteCandidate, vehicleClass: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(route.index ?? 0). \(route.label)").font(.subheadline).bold()
                if route.selected { Text("선택됨").font(.caption2).foregroundColor(.green) }
            }
            Text("\(route.durationText) · \(route.distanceText)").font(.title3).bold()
            Text("\(vehicleClass ?? "차종 미확인") 기준 · \(route.tollText.isEmpty ? "통행료 미확인" : route.tollText)")
                .font(.caption)
            ForEach(Array(route.sections.enumerated()), id: \.offset) { _, section in
                Text("\(section.road) \(section.distanceText) · \(section.congestion)").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(route.selected ? Color.green : Color.clear, lineWidth: 1))
    }
}
