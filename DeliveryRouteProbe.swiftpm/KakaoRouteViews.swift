import SwiftUI

struct KakaoRouteView: View {
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var customers: NaverCustomerStore
    @ObservedObject private var store = KakaoRouteStore.shared
    @State private var mode = KakaoRouteMode.walk
    @State private var fixedID = ""
    @State private var destinationID = ""
    @State private var selected = Set<String>()
    @State private var keyword = ""
    @State private var priority = "DISTANCE"
    @State private var radius = 10_000
    @State private var departure = Date().addingTimeInterval(3600)
    @State private var showSettings = false
    @State private var exporting = false
    @State private var document = DataTextDocument()
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var queried: [KakaoDistanceRecord] = []
    private var endpoints: [RouteEndpoint] {
        let a = sites.records.map { RouteEndpoint(id: "site:" + $0.id, name: $0.name, address: $0.address, coordinate: $0.effectiveCoordinate) }
        let b = customers.records.compactMap { c in c.effectiveCoordinate.map { RouteEndpoint(id: "customer:" + c.id, name: c.name, address: c.capture?.preferredAddress ?? "", coordinate: $0) } }
        return (a + b).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        List {
            Section("입지 거리 조회") {
                Picker("길찾기", selection: $mode) { ForEach(KakaoRouteMode.allCases) { Text($0.title).tag($0) } }
                Picker(mode == .origins ? "고정 목적지" : "출발지", selection: $fixedID) {
                    Text("선택하세요").tag(""); ForEach(endpoints) { Text($0.name + " · " + $0.address).tag($0.id) }
                }
                if mode.isBatch {
                    NativeTextField(mode == .origins ? "출발지 검색" : "목적지 검색", text: $keyword)
                    Text("\(selected.count)/30곳 선택 · 각 장소와 고정 지점 사이의 개별 경로입니다.").font(.caption)
                    ForEach(Array(endpoints.filter { $0.id != fixedID && (keyword.isEmpty || ($0.name + $0.address).localizedCaseInsensitiveContains(keyword)) }.prefix(300))) { point in
                        Button { if selected.contains(point.id) { selected.remove(point.id) } else if selected.count < 30 { selected.insert(point.id) } } label: {
                            HStack { Image(systemName: selected.contains(point.id) ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading) { Text(point.name); Text(point.address).font(.caption) } }
                        }
                    }
                    Picker("길찾기 반경", selection: $radius) { Text("5km").tag(5_000); Text("10km").tag(10_000) }
                    Text("API 탐색 반경 제한 때문에 먼 장소는 실패할 수 있습니다. 먼 구간은 자동차 단일 조회를 사용하세요.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("목적지", selection: $destinationID) { Text("선택하세요").tag(""); ForEach(endpoints) { Text($0.name + " · " + $0.address).tag($0.id) } }
                }
                if !mode.isMap { Picker("탐색 기준", selection: $priority) { Text("최단 거리").tag("DISTANCE"); Text("최단 시간").tag("TIME") } }
                if mode == .future { DatePicker("출발 시각 · 한국 시각", selection: $departure).environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!) }
                if mode == .transit { Text("대중교통은 현재 조회 기준의 대안 경로를 모두 저장합니다. 미래 출발 시각은 자동차 미래 운행에 적용합니다.").font(.caption).foregroundStyle(.secondary) }
                Button(store.isBusy ? "카카오 조회 중…" : "거리·시간 조회하고 저장") { query() }.buttonStyle(.borderedProminent).disabled(store.isBusy || fixedID.isEmpty)
                if store.isBusy { ProgressView(); Button("조회 중단") { task?.cancel() } }
                Button("카카오 API 키·사용량 설정") { showSettings = true }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            Section("저장된 거리 · \(store.resultCount)건") {
                Text("좌표를 수정한 구간은 이전 결과로 표시됩니다. 거리·시간은 API 응답값이며 직선거리와 다릅니다.").font(.caption).foregroundStyle(.secondary)
                Button("전체 저장 결과 CSV 만들기") {
                    Task { do { exportURL = try await store.exportCSV() } catch { self.error = error.localizedDescription } }
                }
                if let exportURL { ShareLink("CSV 파일 저장·공유", item: exportURL) }
                Text("최근 300건을 표시합니다. CSV는 보관된 모든 결과를 내보냅니다.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(store.results.reversed().prefix(300))) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.origin.name + " → " + result.destination.name).bold()
                        Text(result.mode.title + " · " + result.alternative).font(.caption)
                        if let distance = result.distanceMeters, let seconds = result.durationSeconds { Text("\(distance)m · \(seconds)s (\(Double(seconds)/60, specifier: "%.1f")분)") }
                        if let issue = result.issue { Text(issue).foregroundStyle(.orange).font(.caption) }
                        if !result.matches(endpoints) { Text("좌표 수정 또는 장소 삭제 전의 결과 · 재조회 필요").foregroundStyle(.orange).font(.caption) }
                        Text("조회 \(publicTimestamp(result.queriedAt))" + (result.departureTime.map { " · 출발 " + $0 } ?? "")).font(.caption2)
                        if let text = result.landingURL, let url = URL(string: text), url.scheme == "https", url.host == "map.kakao.com" { Link("카카오맵 경로 보기", destination: url).font(.caption) }
                    }
                }
            }
        }.navigationTitle("시설까지 거리").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { KakaoSettingsView(store: store) }
            .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "입지거리자료") { result in if case .failure(let failure) = result { error = failure.localizedDescription } }
            .onDisappear { task?.cancel() }
    }
    private func query() {
        error = nil
        guard let fixed = endpoints.first(where: { $0.id == fixedID }) else { error = "고정 지점을 선택하세요."; return }
        let others = mode.isBatch ? endpoints.filter { selected.contains($0.id) && $0.id != fixed.id } : endpoints.filter { $0.id == destinationID }
        guard !others.isEmpty else { error = "조회할 장소를 선택하세요."; return }
        let requestMode = mode, requestPriority = priority, requestRadius = radius, requestDeparture = departure
        task = Task {
            defer { task = nil }
            do { queried = try await store.query(mode: requestMode, fixed: fixed, others: others, priority: requestPriority, radius: requestRadius, departure: requestMode == .future ? requestDeparture : nil) }
            catch is CancellationError { error = "조회 중단 · 전송한 요청은 사용량에 포함합니다." }
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