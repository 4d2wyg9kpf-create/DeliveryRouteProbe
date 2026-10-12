import SwiftUI

enum FacilityRouteScope: String, CaseIterable, Identifiable {
    case single, origins, destinations
    var id: String { rawValue }
    var title: String { switch self { case .single: return "한 구간"; case .origins: return "여러 출발지 → 한 목적지"; case .destinations: return "한 출발지 → 여러 목적지" } }
}
struct KakaoRouteView: View {
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var customers: NaverCustomerStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = KakaoRouteStore.shared
    @ObservedObject private var naver = NaverAPIStore.shared
    @StateObject private var browser = FacilityRouteWebRunner()
    @State private var provider = FacilityRouteProvider.naverWeb
    @State private var transport = FacilityTransport.walk
    @State private var scope = FacilityRouteScope.single
    @State private var criterion = FacilityRouteCriterion.recommended
    @State private var fixedID = ""
    @State private var destinationID = ""
    @State private var selected = Set<String>()
    @State private var keyword = ""
    @State private var radius = 10_000
    @State private var scheduled = false
    @State private var departure = Date().addingTimeInterval(3600)
    @State private var showKakaoSettings = false
    @State private var showNaverSettings = false
    @State private var showBrowser = false
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var remaining: [FacilityRouteRequest] = []
    @State private var batchScope = FacilityRouteScope.single
    @State private var batchRadius = 10_000
    @State private var completed = 0
    @State private var total = 0
    private var busy: Bool { task != nil }
    private var providers: [FacilityRouteProvider] { FacilityRouteProvider.allCases.filter { $0.supports(transport) } }
    private var criteria: [FacilityRouteCriterion] {
        if transport == .transit { return [.recommended] }
        if provider == .naverAPI { return [.time, .recommended] }
        if provider == .kakaoAPI { return [.time, .distance] }
        return FacilityRouteCriterion.allCases
    }
    private var canSchedule: Bool { transport == .car && provider != .naverAPI }
    private var isKakaoBatch: Bool { provider == .kakaoAPI && !scheduled && scope != .single }
    private var selectionLimit: Int { isKakaoBatch ? 30 : 500 }
    private var endpoints: [RouteEndpoint] {
        let a = sites.records.map { RouteEndpoint(id: "site:" + $0.id, name: $0.name, address: $0.address, coordinate: $0.effectiveCoordinate) }
        let b = customers.records.compactMap { c in c.effectiveCoordinate.map { RouteEndpoint(id: "customer:" + c.id, name: c.name, address: c.capture?.preferredAddress ?? "", coordinate: $0) } }
        return (a + b).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var filtered: [RouteEndpoint] { endpoints.filter { $0.id != fixedID && (keyword.isEmpty || ($0.name + $0.address).localizedCaseInsensitiveContains(keyword)) } }
    var body: some View {
        List {
            optionsSection
            if busy || total > 0 || !remaining.isEmpty { progressSection }
            if browser.webView != nil && showBrowser { browserSection }
            settingsSection
            resultsSection
        }
        .navigationTitle("시설까지 길찾기").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showKakaoSettings) { KakaoSettingsView(store: store) }
        .sheet(isPresented: $showNaverSettings) { NaverAPISettingsView(api: naver) }
        .onChange(of: transport) { _, _ in normalizeOptions() }
        .onChange(of: provider) { _, _ in normalizeOptions() }
        .onChange(of: scenePhase) { _, phase in if phase != .active && busy { stop() } }
        .onDisappear { stop() }
    }
    private var optionsSection: some View {
        Section("조회 조건") {
            Picker("이동방식", selection: $transport) { ForEach(FacilityTransport.allCases) { Text($0.title).tag($0) } }
            Picker("길찾기 제공자", selection: $provider) { ForEach(providers) { Text($0.title).tag($0) } }
            if provider.isWeb { Text(transport == .car ? "PC 웹 · 내부 화면 폭 1,280px. 화면 밖의 결과도 자동으로 읽습니다." : "모바일 웹 · 도보와 대중교통을 구분해 조회합니다.").font(.caption).foregroundStyle(.secondary) }
            Picker("조회 대상", selection: $scope) { ForEach(FacilityRouteScope.allCases) { Text($0.title).tag($0) } }
            Picker(scope == .origins ? "고정 목적지" : "출발지", selection: $fixedID) {
                Text("선택하세요").tag(""); ForEach(endpoints) { Text($0.name + " · " + $0.address).tag($0.id) }
            }.pickerStyle(.navigationLink)
            if scope == .single {
                Picker("목적지", selection: $destinationID) { Text("선택하세요").tag(""); ForEach(endpoints.filter { $0.id != fixedID }) { Text($0.name + " · " + $0.address).tag($0.id) } }.pickerStyle(.navigationLink)
            } else {
                NativeTextField(scope == .origins ? "출발지 검색" : "목적지 검색", text: $keyword)
                Text("\(selected.count)/\(selectionLimit)곳 선택 · 각 장소와 고정 지점 사이의 개별 경로").font(.caption)
                Button("검색된 장소 선택") { selected = Set(filtered.prefix(selectionLimit).map(\.id)) }
                Button("선택 해제") { selected.removeAll() }
                ForEach(Array(filtered.prefix(500))) { point in
                    Button { if selected.contains(point.id) { selected.remove(point.id) } else if selected.count < selectionLimit { selected.insert(point.id) } } label: {
                        HStack(alignment: .top) { Image(systemName: selected.contains(point.id) ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading) { Text(point.name); Text(point.address).font(.caption) } }
                    }
                }
            }
            if criteria.count > 1 { Picker("탐색 기준", selection: $criterion) { ForEach(criteria) { Text($0.title).tag($0) } } }
            if provider.isWeb && transport != .car { Text("웹에 표시되는 대안 경로를 기준으로 조회합니다. 대중교통 총거리가 표시되지 않으면 시간만 저장합니다.").font(.caption).foregroundStyle(.secondary) }
            if canSchedule {
                Toggle("자동차 출발 날짜·시각 지정", isOn: $scheduled)
                if scheduled {
                    DatePicker("출발 · 한국 시각", selection: $departure).environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!)
                    if provider.isWeb { Text(provider == .naverWeb ? "네이버 웹: 10분 단위. 미래 예상시간과 현재 경로 참고 거리를 별도로 저장합니다." : "카카오 웹: 5분 단위, 오늘부터 1년 이내. 미래 예상시간과 현재 경로 참고 거리를 별도로 저장합니다.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if transport == .car { Text("네이버 API는 현재 교통 기준입니다. 출발시각 지정은 카카오 API 또는 PC 웹을 선택하세요.").font(.caption).foregroundStyle(.secondary) }
            if isKakaoBatch {
                Picker("API 탐색 반경", selection: $radius) { Text("5km").tag(5_000); Text("10km").tag(10_000) }
                Text("카카오 다중 출발·목적지 API로 최대 30곳을 한 번에 조회합니다. 반경 밖 구간은 단일 조회를 사용하세요.").font(.caption).foregroundStyle(.secondary)
            } else if scope != .single { Text("같은 조건으로 한 구간씩 순서대로 조회하고, 확인한 결과를 즉시 저장합니다.").font(.caption).foregroundStyle(.secondary) }
            Button("거리·시간 조회하고 저장") { start() }.buttonStyle(.borderedProminent).disabled(fixedID.isEmpty)
        }.disabled(busy)
    }
    private var progressSection: some View {
        Section("조회 진행") {
            ProgressView(value: Double(completed), total: Double(max(1,total)))
            Text("완료 \(completed)/\(total)구간 · 남은 \(remaining.count)구간").monospacedDigit()
            if busy {
                if let current = remaining.first { Text(current.origin.name + " → " + current.destination.name).font(.caption) }
                Text(browser.message).font(.caption).foregroundStyle(.secondary)
                Button("조회 중단", role: .destructive) { stop() }
            } else if !remaining.isEmpty { Button("남은 구간 계속 조회") { runRemaining() }; Text("중단 당시의 제공자·좌표·출발시각으로 이어서 조회합니다.").font(.caption).foregroundStyle(.secondary) }
            if browser.webView != nil { Toggle("진행 웹 화면 보기", isOn: $showBrowser) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }
    private var browserSection: some View {
        Section(browser.desktop ? "PC 크기 웹 화면" : "모바일 웹 화면") {
            Text(browser.desktop ? "가로로 밀면 화면 밖 영역을 볼 수 있습니다. 읽은 값은 아래 앱 결과에 표시합니다." : "웹 결과의 텍스트에서 시간·거리를 자동으로 읽습니다.").font(.caption).foregroundStyle(.secondary)
            FacilityRouteWebCanvas(webView: browser.webView, desktop: browser.desktop).frame(height: 420).listRowInsets(EdgeInsets())
        }
    }
    private var settingsSection: some View {
        Section("API 설정") {
            Button("네이버 API 키·사용량") { showNaverSettings = true }.disabled(busy)
            Button("카카오 API 키·사용량") { showKakaoSettings = true }.disabled(busy)
            if let q = naver.quotas["directions"] { Text("네이버 자동차 월 사용 \(q.used.formatted())/\(q.limit.formatted())회").font(.caption) }
            if total == 0, let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private var resultsSection: some View {
        Section("저장된 결과 · \(store.resultCount)건") {
            Text("API 값과 웹 표시값을 제공자별로 구분합니다. 웹 표시값은 반올림된 값이며, 거리 미제공은 0으로 계산하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            Button("전체 저장 결과 CSV 만들기") { Task { do { exportURL = try await store.exportCSV() } catch { self.error = error.localizedDescription } } }
            if let exportURL { ShareLink("CSV 파일 저장·공유", item: exportURL) }
            Text("최근 300건 표시 · CSV는 전체 결과").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(store.results.reversed().prefix(300))) { result in resultRow(result) }
        }
    }
    private func resultRow(_ r: KakaoDistanceRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(r.origin.name + " → " + r.destination.name).bold()
            Text((FacilityRouteProvider(rawValue: r.provider ?? "kakaoAPI")?.title ?? "카카오 API") + " · " + (r.mode == .walk ? "도보" : r.mode == .transit ? "대중교통" : "자동차") + " · " + r.alternative).font(.caption)
            if let seconds = r.durationSeconds { Text("\(Double(seconds)/60, specifier: "%.1f")분" + (r.distanceMeters.map { " · \($0)m" } ?? " · 총거리 미제공")) }
            if let distance = r.referenceDistanceMeters { Text("현재 경로 참고 거리 \(distance)m · 미래 경로 거리로 확정하지 않음").font(.caption).foregroundStyle(.secondary) }
            if let departure = r.departureTime { Text("지정 출발 \(departure) · 미래 예상").font(.caption) }
            else { Text("조회 당시 출발 기준").font(.caption).foregroundStyle(.secondary) }
            if let issue = r.issue { Text(issue).foregroundStyle(.orange).font(.caption) }
            if !r.matches(endpoints) { Text("좌표 수정 또는 장소 삭제 전의 결과 · 재조회 필요").foregroundStyle(.orange).font(.caption) }
            Text("조회 \(publicTimestamp(r.queriedAt))").font(.caption2)
            if let raw = r.rawSummary { DisclosureGroup("읽은 웹 원문") { Text(raw).font(.caption).textSelection(.enabled) } }
            if let value = r.landingURL, let url = URL(string: value), url.scheme == "https", ["map.naver.com", "m.map.naver.com", "m.search.naver.com", "map.kakao.com", "m.map.kakao.com"].contains(url.host ?? "") { Link("조회 경로 보기", destination: url).font(.caption) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func normalizeOptions() {
        if !providers.contains(provider) { provider = .naverWeb }
        if !criteria.contains(criterion) { criterion = criteria[0] }
        if !canSchedule { scheduled = false }
    }
    private func start() {
        error = nil
        guard let fixed = endpoints.first(where: { $0.id == fixedID }) else { error = "고정 지점을 선택하세요."; return }
        let others = scope == .single ? endpoints.filter { $0.id == destinationID && $0.id != fixedID } : endpoints.filter { selected.contains($0.id) && $0.id != fixedID }
        guard !others.isEmpty, others.count <= selectionLimit else { error = "조회할 장소와 선택 개수를 확인하세요."; return }
        let requests = others.map { FacilityRouteRequest(provider: provider, transport: transport, criterion: criterion, origin: scope == .origins ? $0 : fixed, destination: scope == .origins ? fixed : $0, departure: scheduled ? departure : nil) }
        do { for request in requests { try request.validate() } } catch { self.error = error.localizedDescription; return }
        remaining = requests; completed = 0; total = requests.count; batchScope = scope; batchRadius = radius
        runRemaining()
    }
    private func stop() { if busy { task?.cancel(); browser.cancel() } }
    private func runRemaining() {
        guard !busy, !remaining.isEmpty else { return }
        error = nil; showBrowser = remaining.first?.provider.isWeb == true
        task = Task {
            defer { task = nil }
            do {
                while let request = remaining.first {
                    try Task.checkCancellation(); try request.validate()
                    if request.provider == .kakaoAPI, request.departure == nil, batchScope != .single {
                        let chunk = Array(remaining.prefix(30)), origins = batchScope == .origins
                        let fixed = origins ? request.destination : request.origin, others = chunk.map { origins ? $0.origin : $0.destination }
                        let rows = try await store.query(mode: origins ? .origins : .destinations, fixed: fixed, others: others, priority: request.criterion.kakaoPriority, radius: batchRadius, departure: nil)
                        let failed = Set(rows.filter { $0.issue != nil }.map { origins ? $0.origin.id : $0.destination.id })
                        let successful = chunk.filter { !failed.contains(origins ? $0.origin.id : $0.destination.id) }
                        completed += successful.count; remaining.removeAll { item in successful.contains { $0.id == item.id } }
                        if !failed.isEmpty { throw PlannerFailure.message("일부 API 구간이 실패했습니다. 오류 결과를 확인한 뒤 남은 구간을 다시 조회하세요.") }
                    } else {
                        let rows: [KakaoDistanceRecord]
                        if request.provider.isWeb { rows = try await browser.query(request); try store.saveExternalResults(rows) }
                        else if request.provider == .naverAPI {
                            let body = try await naver.directions(startLongitude: request.origin.coordinate.longitude, startLatitude: request.origin.coordinate.latitude, goalLongitude: request.destination.coordinate.longitude, goalLatitude: request.destination.coordinate.latitude, option: request.criterion.naverOption)
                            rows = try FacilityRouteRecords.naver(body, request: request); try store.saveExternalResults(rows)
                        } else { rows = try await store.query(mode: request.departure == nil ? .car : .future, fixed: request.origin, others: [request.destination], priority: request.criterion.kakaoPriority, radius: batchRadius, departure: request.departure) }
                        if rows.contains(where: { $0.issue != nil }) { throw PlannerFailure.message("이 구간의 경로 조회가 실패했습니다. 저장된 오류를 확인하세요.") }
                        completed += 1; remaining.removeFirst()
                    }
                    if !remaining.isEmpty { try await Task.sleep(nanoseconds: 1_500_000_000) }
                }
            } catch is CancellationError { error = "조회 중단 · 완료 결과는 보관했습니다. 전송된 API 요청은 사용량에 포함됩니다." }
            catch { self.error = error.localizedDescription }
        }
    }
}
struct KakaoSettingsView: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: KakaoRouteStore
    @State private var key = ""
    @State private var mapFree = false
    @State private var naviFree = false
    @State private var mode = KakaoRouteMode.walk
    @State private var usage = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("카카오 REST API") {
                    NativeTextField(store.settings.key.isEmpty ? "REST API 키" : "새 키 입력 · 빈칸은 기존 키 유지", text: $key, secure: true)
                    Toggle("카카오맵 사용 ON · 무료 쿼터 앱 확인", isOn: $mapFree)
                    Toggle("카카오내비 길찾기 사용·무료 쿼터 확인", isOn: $naviFree)
                    Button("키·설정 저장") { do { inputs.finishEditing(); try store.saveSettings(key: key, mapFree: mapFree, naviFree: naviFree); key = ""; error = nil } catch { self.error = error.localizedDescription } }
                    Text("설정은 저장 버튼을 누르면 적용되고, 연결한 iCloud 폴더에 자동 동기화됩니다. 카카오맵 무료 쿼터는 개발자 계정에서 첫 활성화 앱에 제공됩니다.").font(.caption).foregroundStyle(.secondary)
                    Link("카카오디벨로퍼스 앱 설정", destination: URL(string: "https://developers.kakao.com/console/app")!)
                    Link("무료 쿼터 안내", destination: URL(string: "https://developers.kakao.com/docs/ko/getting-started/quota")!)
                }
                Section("일간 사용량 · 공유 기기 합산") {
                    ForEach(KakaoRouteMode.allCases) { mode in LabeledContent(mode.title, value: "\(store.used(mode))/\(mode.dailyLimit)") }
                    Button("인터넷 기준 시각 확인") { Task { await store.refreshClock() } }
                    Picker("제공자 사용량 입력 API", selection: $mode) { ForEach(KakaoRouteMode.allCases) { Text($0.title).tag($0) } }
                    NativeTextField("카카오 콘솔의 오늘 총 사용량", text: $usage, keyboard: .numberPad)
                    Button("총 사용량 반영 · 감소 없이 저장") { do { guard let value = Int(usage) else { throw DeviceShareError.invalid }; try store.raiseUsage(mode, used: value) } catch { self.error = error.localizedDescription } }
                    Text("이 앱 외부에서 사용한 횟수는 카카오 콘솔에서 확인해 반영하세요. 동시에 오프라인인 기기의 요청은 iCloud 도착 후 합산됩니다.").font(.caption).foregroundStyle(.secondary)
                    DeviceSharingSettingsLink()
                }
                if let error = error ?? store.errorMessage { Text(error).foregroundStyle(.red) }
            }.navigationTitle("카카오 API 설정").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
                .onAppear { mapFree = store.settings.mapFreeConfirmed; naviFree = store.settings.naviFreeConfirmed }
        }
    }
}