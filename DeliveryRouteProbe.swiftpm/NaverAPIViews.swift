import SwiftUI

struct NaverSearchScreen: View {
    @ObservedObject var planner: PlannerStore
    @ObservedObject var browser: BrowserModel
    @Binding var showWeb: Bool
    @ObservedObject private var api = NaverAPIStore.shared
    @EnvironmentObject private var inputs: NativeInputSession
    @EnvironmentObject private var customers: NaverCustomerStore
    @State private var mode = 0
    @State private var query = ""
    @State private var name = ""
    @State private var address = ""
    @State private var results: [NaverAPIResult] = []
    @State private var selection: NaverPlaceCapture?
    @State private var showSettings = false
    @State private var showCustomers = false
    @State private var message = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("찾는 방법", selection: $mode) {
                        Text("업체 검색").tag(0)
                        Text("주소 → 좌표").tag(1)
                    }.pickerStyle(.segmented)
                    if mode == 0 {
                        NativeTextField("업체명 · 지역을 함께 입력하면 더 정확합니다", text: $query).frame(minHeight: 44)
                    } else {
                        NativeTextField("거래처 이름 · 선택 사항", text: $name).frame(minHeight: 44)
                        NativeTextField("전체 주소 · 예: 대전 중구 유천로 35", text: $address).frame(minHeight: 44)
                    }
                    Button(api.isBusy ? "처리 중…" : mode == 0 ? "네이버 API로 검색" : "네이버 API로 좌표 변환") { search() }
                        .buttonStyle(.borderedProminent)
                        .disabled(api.isBusy || (mode == 0 ? query : address).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !api.hasSearchKeys || !api.hasMapsKeys {
                        Button("네이버 API 키 설정") { inputs.finishEditing(); showSettings = true }
                    }
                    Text(mode == 0 ? "검색은 최대 5곳을 반환합니다. 원하는 지점이 없으면 업체명에 시·구·동을 더하거나 주소로 변환하세요." : "주소 변환은 Maps의 Geocoding 키를 사용합니다. 지도 화면을 띄울 필요가 없습니다.").font(.caption).foregroundColor(.secondary)
                } header: { Text("지도 없이 장소·좌표 찾기") }
                if !message.isEmpty { Text(message).font(.caption) }
                if let error { Text(error).font(.caption).foregroundColor(.red) }
                if let error = api.errorMessage { Text(error).font(.caption).foregroundColor(.red) }
                if !results.isEmpty {
                    Section("검색 결과 · 장소를 눌러 저장") {
                        ForEach(results) { result in
                            Button { inputs.finishEditing(); selection = result.capture } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.capture.name).bold().foregroundColor(.primary)
                                    Text(result.capture.preferredAddress).font(.subheadline).foregroundColor(.primary)
                                    if !result.category.isEmpty { Text(result.category).font(.caption).foregroundColor(.secondary) }
                                    NaverCoordinateLabel(capture: result.capture)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Section("거래처와 이번 배송") {
                    Button("거래처 목록 · 이번 배송 선택") { inputs.finishEditing(); showCustomers = true }
                    Button("네이버 개인 저장목록 가져오기") { inputs.finishEditing(); browser.openSavedLists(customers); showWeb = true }
                    Text("API 검색으로 저장한 거래처 중 이번에 나갈 곳을 목록에서 체크합니다. 개인 저장목록은 네이버 웹 화면에서 폴더를 선택해 가져오며 좌표 변환에는 API를 사용합니다.").font(.caption).foregroundColor(.secondary)
                }
                NaverQuotaSection(api: api)
                Section {
                    Button("기존 웹 지도 · 공유 링크 · 경로 읽기") { inputs.finishEditing(); browser.openHome(); showWeb = true }
                }
            }
            .navigationTitle("네이버 검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { inputs.finishEditing(); showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("네이버 API 설정") } }
            .navigationDestination(isPresented: $showWeb) { ProbeView(model: browser, planner: planner).navigationTitle("네이버 저장목록 · 웹 지도").navigationBarTitleDisplayMode(.inline) }
            .sheet(isPresented: $showSettings) { NaverAPISettingsView(api: api) }
            .sheet(isPresented: $showCustomers) { NaverCustomerCatalogView(planner: planner, browser: browser) }
            .sheet(item: $selection) { capture in NaverAPISelectionView(capture: capture) { message = $0 } }
            .task { await api.refreshQuotas() }
            .onChange(of: mode) { _, _ in results = []; error = nil; message = "" }
        }
    }
    private func search() {
        inputs.finishEditing(); error = nil; message = ""; results = []
        let chosenMode = mode, searchQuery = query, enteredAddress = address, enteredName = name
        Task {
            do {
                if chosenMode == 0 {
                    let found = try await api.search(searchQuery)
                    if mode == chosenMode { results = found; message = found.isEmpty ? "검색 결과가 없습니다. 업체명에 지역을 더하거나 주소로 검색해 주세요." : "\(found.count)곳을 찾았습니다." }
                } else {
                    let found = try await api.address(enteredAddress, name: enteredName)
                    if mode == chosenMode { selection = found; message = "주소와 일치하는 좌표를 찾았습니다." }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct NaverCoordinateLabel: View {
    let capture: NaverPlaceCapture
    var body: some View {
        if let coordinate = capture.coordinate {
            Text("경도 \(coordinate.longitude, specifier: "%.7f") · 위도 \(coordinate.latitude, specifier: "%.7f")").font(.caption).foregroundColor(.secondary)
        }
    }
}

private struct NaverAPISelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var customers: NaverCustomerStore
    @EnvironmentObject private var inputs: NativeInputSession
    let capture: NaverPlaceCapture
    let saved: (String) -> Void
    @State private var name: String
    @State private var error: String?
    init(capture: NaverPlaceCapture, saved: @escaping (String) -> Void) {
        self.capture = capture; self.saved = saved; _name = State(initialValue: capture.name)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("선택한 장소") {
                    Text(capture.name).bold()
                    Text(capture.preferredAddress)
                    if !capture.jibunAddress.isEmpty { Text("지번: \(capture.jibunAddress)").font(.caption) }
                    NaverCoordinateLabel(capture: capture)
                    Text("좌표 제공: \(capture.geocodeProvider ?? "NAVER")").font(.caption)
                }
                Section("거래처 목록에 저장") {
                    NativeTextField("거래처 이름", text: $name).frame(minHeight: 44)
                    Text("검색·주소 변환 좌표는 업체 또는 건물 위치입니다. 배송계획에서 실제 차량 정차 위치인지 확인해 주세요.").font(.caption).foregroundColor(.secondary)
                    if let error { Text(error).font(.caption).foregroundColor(.red) }
                    Button("거래처 목록에 저장") {
                        inputs.finishEditing()
                        do { let added = try customers.save(capture, name: name); saved(added ? "거래처를 저장했습니다. ‘이번 배송 선택’에서 방문할 곳을 체크하세요." : "기존 거래처의 주소·좌표를 갱신했습니다."); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.navigationTitle("장소 확인").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { inputs.finishEditing(); dismiss() } } }
        }
    }
}

struct NaverQuotaSection: View {
    @ObservedObject var api: NaverAPIStore
    @State private var usageProvider: String?
    @State private var usageText = ""
    var body: some View {
        Section("네이버 무료 잔여량 · 이 기기 기준") {
            quotaRow("search", title: "지역 검색 · 하루 25,000회")
            if api.searchProvider == .hub { quotaRow("searchMonth", title: "HUB 지역 검색 · 월 최대 775,000회") }
            quotaRow("maps", title: "Maps 주소 변환 · 월 3,000,000건")
            Button("잔여량·기준 시간 새로 확인") { Task { await api.refreshQuotas() } }.disabled(api.isBusy)
            Text("요청 전에 기록하며 실패·중단도 포함합니다. 다른 기기·앱의 사용량은 자동 조회하지 못합니다. 같은 검색 Client ID의 다른 검색 API, 같은 Maps 대표 계정의 다른 앱에서 사용한 총 횟수도 반영해 주세요.").font(.caption).foregroundColor(.secondary)
            Text("클라우드 한도는 한국시간 매일 0시·매월 1일 0시에 초기화합니다. 앱은 경계에서 5분을 더 기다리며 서버가 계속 제한하면 다시 차단합니다. HUB 일·월 한도 중 하나라도 소진되면 검색할 수 없습니다.").font(.caption).foregroundColor(.secondary)
        }
        .sheet(isPresented: Binding(get: { usageProvider != nil }, set: { if !$0 { usageProvider = nil } })) {
            NavigationStack {
                Form {
                    Text("현재 기간에 같은 키·계정으로 사용한 총 횟수를 입력하세요. 현재 기록보다 늘리는 보정만 가능합니다. HUB 일 사용량을 늘린 만큼 월 사용량에도 합산합니다. 일 사용량을 먼저 반영한 뒤 월 총량을 확인하세요.").font(.caption)
                    NativeTextField("총 사용 횟수", text: $usageText, keyboard: .numberPad, digitsOnly: true).frame(minHeight: 44)
                    if let error = api.errorMessage { Text(error).font(.caption).foregroundColor(.red) }
                    Button("사용량 반영") {
                        guard let provider = usageProvider, let used = Int(usageText) else { return }
                        Task { await api.raiseUsage(provider: provider, used: used); if api.errorMessage == nil { usageProvider = nil } }
                    }.disabled(api.isBusy || Int(usageText) == nil)
                }.navigationTitle("네이버 사용량 반영")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { usageProvider = nil }.disabled(api.isBusy) } }
            }
        }
    }
    @ViewBuilder private func quotaRow(_ provider: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline)
            if let quota = api.quotas[provider] {
                Text("\(quota.remaining.formatted())회 남음 / \(quota.limit.formatted())회").bold()
                ProgressView(value: Double(quota.remaining), total: Double(quota.limit))
                Text("기록 \(quota.used.formatted())회 · 다음 초기화 \(resetTime(quota.resetMillis))").font(.caption)
                if quota.blocked { Text(quota.inGrace ? "초기화 대기 중" : "한도 소진·서버 제한으로 요청 차단").font(.caption).foregroundColor(.orange) }
                Button("다른 곳에서 사용한 횟수 반영") { usageText = String(quota.used); usageProvider = provider; api.errorMessage = nil }.font(.caption).disabled(api.isBusy)
            } else { Text("키 설정 후 기준 시간을 확인하세요.").font(.caption).foregroundColor(.secondary) }
            if provider == "maps" && !api.mapsFreeConfirmed { Text("새 Maps 무료 대표 계정 확인 필요").font(.caption).foregroundColor(.orange) }
            if provider == "search" && api.searchProvider == .hub && !api.searchFreeConfirmed { Text("HUB 현재 무료 제공 확인 필요").font(.caption).foregroundColor(.orange) }
        }
    }
    private func resetTime(_ value: Double) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "ko_KR"); format.timeZone = TimeZone(identifier: "Asia/Seoul"); format.dateFormat = "M/d HH:mm"
        return format.string(from: Date(timeIntervalSince1970: value / 1000))
    }
}

struct NaverAPISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var api: NaverAPIStore
    @State private var searchID = ""
    @State private var searchSecret = ""
    @State private var searchProvider = NaverSearchProvider.hub
    @State private var searchFreeConfirmed = false
    @State private var mapsID = ""
    @State private var mapsSecret = ""
    @State private var freeConfirmed = false
    var body: some View {
        NavigationStack {
            Form {
                Section("네이버 검색 · 키 발급 서비스") {
                    Picker("검색 키 발급처", selection: $searchProvider) {
                        Text("NAVER API HUB · 신규 신청").tag(NaverSearchProvider.hub)
                        Text("Developers · 기존 발급 키").tag(NaverSearchProvider.legacy)
                    }
                    if searchProvider == .hub {
                        Link("HUB 등록 안내", destination: URL(string: "https://guide.ncloud-docs.com/docs/apihub-application")!)
                        Text("콘솔에서 Application Services → NAVER API HUB → Application 등록 → NAVER 검색의 ‘지역’을 선택하세요. CLOVA가 표시되는 AI·NAVER API 메뉴에서는 등록하지 않습니다.").font(.caption)
                        LabeledContent("Application 이름") { Text("DeliveryRoute-Search").textSelection(.enabled) }
                        Text("검색 등록에는 Web URL·Android 패키지·iOS Bundle ID를 입력하지 않습니다. 인증 정보의 Client ID와 Client Secret을 아래에 입력하세요.").font(.caption)
                        Toggle("현재 클라우드 콘솔에서 HUB 무료 제공 중임을 확인", isOn: $searchFreeConfirmed)
                        Text("HUB는 한시적으로 무료입니다. 현재 일 25,000회·월 최대 775,000회를 안내하며, 무료 확인 전 또는 한도 소진 뒤에는 검색을 차단합니다. 유료 전환 공지 시 이 확인을 끄세요.").font(.caption)
                    } else {
                        Link("검색 API 이관 공지", destination: URL(string: "https://developers.naver.com/notice/article/32530")!)
                        Text("2026년 7월 31일 이전에 Developers에서 등록한 기존 검색 키만 사용합니다. 신규 등록은 HUB에서 진행하세요. 기존 키는 2027년 6월 30일까지 지원하며 HUB 키와 호환되지 않습니다. 기존 일 사용량을 유지합니다.").font(.caption)
                    }
                    SecureField(api.hasSearchKeys ? "Client ID · 변경 시 입력" : "검색 Client ID", text: $searchID)
                    SecureField(api.hasSearchKeys ? "Client Secret · 변경 시 입력" : "검색 Client Secret", text: $searchSecret)
                }
                Section("네이버 클라우드 · 새 Maps Geocoding") {
                    Link("Maps 안내·신청", destination: URL(string: "https://www.ncloud.com/product/applicationService/maps")!)
                    Text("콘솔에서 Application Services → Maps → Application 등록으로 들어가 Geocoding만 선택하세요. HUB 검색 키와는 다른 키입니다.").font(.caption)
                    LabeledContent("Application 이름") { Text("DeliveryRoute-Maps").textSelection(.enabled) }
                    Text("Geocoding만 사용하면 Web URL·Android 패키지·iOS Bundle ID 등록은 필요하지 않습니다. 지도 SDK를 추가해 iOS ID 입력이 필요하다면 아래 값을 사용하세요.").font(.caption)
                    Text("kr.deliverytools.routeprobe").font(.caption.monospaced()).textSelection(.enabled)
                    SecureField(api.hasMapsKeys ? "Client ID · 변경 시 입력" : "Maps Client ID", text: $mapsID)
                    SecureField(api.hasMapsKeys ? "Client Secret · 변경 시 입력" : "Maps Client Secret", text: $mapsSecret)
                    Toggle("이 계정이 Maps 무료 이용 대표 계정임을 확인", isOn: $freeConfirmed)
                    Text("월 300만 건 무료 제공은 대표 계정 하나에 적용됩니다. 확인 전에는 Maps 호출을 차단합니다. 초과분은 유료이므로 외부 사용 횟수도 반영해 주세요.").font(.caption)
                }
                Section {
                    Text("빈 칸은 기존 키를 유지합니다. 키와 사용량은 기기 보관함에 저장하며 키를 바꿔도 이전 사용량 기록은 남습니다. Maps 무료 한도 기록은 앱별 키 사이에서도 공유합니다.").font(.caption).foregroundColor(.secondary)
                    if let error = api.errorMessage { Text(error).font(.caption).foregroundColor(.red) }
                    Button("설정 저장") {
                        if api.saveSettings(searchID: searchID, searchSecret: searchSecret, mapsID: mapsID, mapsSecret: mapsSecret, freeConfirmed: freeConfirmed, searchProvider: searchProvider, searchFreeConfirmed: searchFreeConfirmed) { searchID = ""; searchSecret = ""; mapsID = ""; mapsSecret = ""; dismiss() }
                    }.buttonStyle(.borderedProminent).disabled(api.isBusy)
                }
            }.navigationTitle("네이버 API 설정").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(api.isBusy) } }
                .onAppear { freeConfirmed = api.mapsFreeConfirmed; searchProvider = api.searchProvider; searchFreeConfirmed = api.searchFreeConfirmed }
        }
    }
}
