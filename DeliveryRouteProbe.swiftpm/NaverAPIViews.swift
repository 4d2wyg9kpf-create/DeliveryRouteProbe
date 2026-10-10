import SwiftUI

struct NaverSearchScreen: View {
    @ObservedObject var planner: PlannerStore
    @ObservedObject var browser: BrowserModel
    @Binding var showWeb: Bool
    @ObservedObject private var api = NaverAPIStore.shared
    @EnvironmentObject private var inputs: NativeInputSession
    @EnvironmentObject private var customers: NaverCustomerStore
    @EnvironmentObject private var sites: SiteTargetStore
    @State private var mode = 0
    @State private var destination = NaverImportDestination.customers
    @State private var query = ""
    @State private var name = ""
    @State private var address = ""
    @State private var sharedLink = ""
    @State private var results: [NaverAPIResult] = []
    @State private var selection: NaverPlaceCapture?
    @State private var showSettings = false
    @State private var showCustomers = false
    @State private var message = ""
    @State private var error: String?
    private var importing: Bool { browser.isOpeningSharedLink || browser.isImportingSavedList || browser.waitingForSavedFolder || browser.isReadingPlace }
    private var importingWeb: Bool { browser.isImportingSavedList || browser.waitingForSavedFolder || browser.isReadingPlace || (browser.isOpeningSharedLink && browser.sharedLinkUsesWeb) }
    var body: some View {
        NavigationStack {
            Form {
                Section("가져온 장소를 저장할 곳") {
                    Picker("저장 목록", selection: $destination) {
                        ForEach(NaverImportDestination.allCases) { Text($0.title).tag($0) }
                    }.disabled(importing || api.isBusy)
                    Text("거래처 \(customers.records.count)곳 · 평가대상지 \(sites.records.count)곳").font(.caption).foregroundStyle(.secondary)
                }
                Section("장소 이름 · 주소 · 좌표 가져오기") {
                    Picker("찾는 방법", selection: $mode) {
                        Text("검색어").tag(0)
                        Text("주소").tag(1)
                        Text("공유 링크").tag(2)
                    }.pickerStyle(.segmented).disabled(importing || api.isBusy)
                    if mode == 0 {
                        NativeTextField("업체명 · 지역을 함께 입력하세요", text: $query).frame(minHeight: 44)
                    } else if mode == 1 {
                        NativeTextField("장소 이름 · 선택 사항", text: $name).frame(minHeight: 44)
                        NativeTextField("전체 주소 · 예: 대전 중구 유천로 35", text: $address).frame(minHeight: 44)
                    } else {
                        NativeTextField("네이버지도 장소·목록 공유 링크", text: $sharedLink, keyboard: .URL).frame(minHeight: 44)
                        PasteButton(payloadType: String.self) { values in sharedLink = values.first ?? "" }
                        Text("네이버지도의 공유문 전체를 붙여넣으세요. 주소 공유는 지도 화면 없이 좌표로 변환합니다. 장소는 확인 후 저장하고, 목록은 모든 장소를 가져옵니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(api.isBusy || importing ? "처리 중…" : mode == 0 ? "네이버 검색" : mode == 1 ? "주소 → 좌표 변환" : "공유 링크 가져오기") { search() }
                        .buttonStyle(.borderedProminent)
                        .disabled(api.isBusy || importing || enteredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if mode != 2 {
                        Text(mode == 0 ? "검색은 최대 5곳을 반환합니다. 원하는 지점이 없으면 업체명에 지역을 더하거나 주소로 변환하세요." : "Maps Geocoding으로 주소에 맞는 좌표를 가져옵니다. 지도 화면을 띄울 필요가 없습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !api.hasSearchKeys || !api.hasMapsKeys { Button("네이버 API 키 설정") { inputs.finishEditing(); showSettings = true } }
                }
                if !message.isEmpty { Text(message).font(.caption) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = api.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = browser.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                if importing || !browser.savedListProgress.isEmpty {
                    Section("링크 · 목록 가져오기") {
                        if importing { ProgressView() }
                        Text(browser.savedListProgress.isEmpty ? browser.status : browser.savedListProgress).font(.caption)
                        if importing { Button("중단") { browser.cancelLinkImport() } }
                        if let report = browser.savedListReport, !report.failures.isEmpty {
                            DisclosureGroup("가져오지 못한 \(report.failures.count)곳") {
                                ForEach(Array(report.failures.enumerated()), id: \.offset) { _, value in Text(value).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        if browser.sharedLinkUsesWeb || browser.isImportingSavedList || browser.waitingForSavedFolder {
                            Button("네이버 로그인 · 링크 접근 확인") { inputs.finishEditing(); showWeb = true }
                        }
                    }
                }
                if !results.isEmpty {
                    Section("검색 결과 · 눌러서 저장") {
                        ForEach(results) { result in
                            Button { inputs.finishEditing(); selection = result.capture } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.capture.name).bold().foregroundStyle(.primary)
                                    Text(result.capture.preferredAddress).font(.subheadline).foregroundStyle(.primary)
                                    if !result.category.isEmpty { Text(result.category).font(.caption).foregroundStyle(.secondary) }
                                    NaverCoordinateLabel(capture: result.capture)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if results.count > 1 { Button("검색 결과 \(results.count)곳을 \(destination.title)에 저장") { saveAll() } }
                    }
                }
                Section("목록 관리") {
                    Button("티맵 거래처 목록 · 이번 배송 선택") { inputs.finishEditing(); showCustomers = true }
                    Button("네이버에 저장한 장소 목록 열기") {
                        inputs.finishEditing()
                        browser.openSavedLists(customers, sites: sites, destination: destination); showWeb = true
                    }.disabled(importing || api.isBusy)
                    Text("개인 목록은 네이버 로그인이 필요할 수 있습니다. 공유·검색 좌표가 없으면 읽은 주소를 API로 변환하고, 확인된 장소만 저장합니다.").font(.caption).foregroundStyle(.secondary)
                }
                NaverQuotaSection(api: api)
            }
            .background {
                // A wide, invisible document viewport lets shared links resolve
                // without making the user fit a desktop map onto an iPhone.
                if !showWeb && importingWeb { MapWebView(webView: browser.webView).frame(width: 900, height: 700).opacity(0).allowsHitTesting(false).accessibilityHidden(true) }
            }.clipped()
            .navigationTitle("네이버검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { inputs.finishEditing(); showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("네이버 API 설정") } }
            .navigationDestination(isPresented: $showWeb) { NaverLinkWebView(browser: browser) }
            .sheet(isPresented: $showSettings) { NaverAPISettingsView(api: api) }
            .sheet(isPresented: $showCustomers) { NaverCustomerCatalogView(planner: planner, browser: browser) }
            .sheet(item: $selection) { capture in NaverAPISelectionView(capture: capture, destination: destination) { message = $0 } }
            .task { await api.refreshQuotas() }
            .onChange(of: browser.placeCapture?.capturedAt) { _, _ in
                if let capture = browser.placeCapture { selection = capture }
            }
            .onChange(of: mode) { _, _ in results = []; error = nil; message = "" }
        }
    }
    private var enteredText: String { mode == 0 ? query : mode == 1 ? address : sharedLink }
    private func search() {
        inputs.finishEditing(); error = nil; message = ""; results = []
        if mode == 2 {
            do { try browser.openSharedLink(sharedLink, customers: customers, sites: sites, destination: destination) }
            catch { self.error = error.localizedDescription }
            return
        }
        let chosenMode = mode, searchQuery = query, enteredAddress = address, enteredName = name
        Task {
            do {
                if chosenMode == 0 {
                    let found = try await api.search(searchQuery)
                    if mode == chosenMode { results = found; message = found.isEmpty ? "검색 결과가 없습니다. 지역을 더하거나 주소로 검색해 주세요." : "\(found.count)곳을 찾았습니다." }
                } else {
                    let found = try await api.address(enteredAddress, name: enteredName)
                    if mode == chosenMode { selection = found; message = "주소와 일치하는 좌표를 찾았습니다." }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func saveAll() {
        inputs.finishEditing(); error = nil
        var added = 0, updated = 0
        do {
            for result in results {
                if try NaverImportSink.save(result.capture, destination: destination, customers: customers, sites: sites) { added += 1 } else { updated += 1 }
            }
            message = "\(destination.title): 새로 저장 \(added)곳 · 기존 장소 갱신 \(updated)곳"
        } catch { message = "\(added + updated)곳 저장됨"; self.error = error.localizedDescription }
    }
}

struct NaverLinkWebView: View {
    @ObservedObject var browser: BrowserModel
    var body: some View {
        VStack(spacing: 8) {
            if browser.isLoading { ProgressView(value: browser.progress) }
            Text(browser.savedListProgress.isEmpty ? browser.status : browser.savedListProgress).font(.caption).padding(.horizontal)
            if let error = browser.errorMessage { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            HStack {
                Button { _ = browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack)
                Button("새로고침") { browser.webView.reload() }
                Button("선택 장소 읽기", action: browser.readSelectedPlace).disabled(browser.isLoading || browser.isReadingPlace || browser.isImportingSavedList || browser.isOpeningSharedLink)
            }.buttonStyle(.bordered)
            MapWebView(webView: browser.webView)
        }.navigationTitle("네이버 목록 · 로그인 확인").navigationBarTitleDisplayMode(.inline)
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
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject private var api = NaverAPIStore.shared
    let saved: (String) -> Void
    @State private var capture: NaverPlaceCapture
    @State private var destination: NaverImportDestination
    @State private var name: String
    @State private var error: String?
    @State private var resolving = false
    init(capture: NaverPlaceCapture, destination: NaverImportDestination, saved: @escaping (String) -> Void) {
        self.saved = saved; _capture = State(initialValue: capture); _name = State(initialValue: capture.name)
        _destination = State(initialValue: destination)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("선택한 장소") {
                    Text(capture.name).bold()
                    Text(capture.preferredAddress)
                    if !capture.jibunAddress.isEmpty { Text("지번: \(capture.jibunAddress)").font(.caption) }
                    NaverCoordinateLabel(capture: capture)
                    if capture.coordinate == nil {
                        Text(capture.coordinateIssue.isEmpty ? "주소에서 좌표를 변환해 주세요." : capture.coordinateIssue).font(.caption).foregroundStyle(.orange)
                        Button(resolving ? "좌표 변환 중…" : "읽은 주소로 좌표 변환") {
                            inputs.finishEditing(); resolving = true; error = nil
                            Task {
                                defer { resolving = false }
                                do { capture = try await api.resolve(capture) } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(resolving || api.isBusy || capture.preferredAddress.isEmpty)
                    } else { Text("좌표 제공: \(capture.geocodeProvider ?? "NAVER")").font(.caption) }
                }
                Section("목록에 저장") {
                    Picker("저장할 곳", selection: $destination) { ForEach(NaverImportDestination.allCases) { Text($0.title).tag($0) } }
                    NativeTextField("장소 이름", text: $name).frame(minHeight: 44)
                    Text("장소 좌표는 건물 위치일 수 있습니다. 배송 시에는 실제 차량 정차 위치인지 확인하세요.").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("\(destination.title)에 저장") {
                        inputs.finishEditing()
                        do {
                            let added = try NaverImportSink.save(capture, name: name, destination: destination, customers: customers, sites: sites)
                            saved("\(destination.title)에 \(added ? "저장했습니다." : "기존 장소를 갱신했습니다.")"); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(resolving || capture.coordinate == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    if api.hasSearchKeys && searchProvider == api.searchProvider {
                        Label("검색 API 키 저장됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("업데이트 후에도 자동으로 불러옵니다. 키를 바꿀 때만 입력하세요.").font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField(api.hasSearchKeys && searchProvider == api.searchProvider ? "Client ID · 변경 시 입력" : "검색 Client ID", text: $searchID)
                    SecureField(api.hasSearchKeys && searchProvider == api.searchProvider ? "Client Secret · 변경 시 입력" : "검색 Client Secret", text: $searchSecret)
                }
                Section("네이버 클라우드 · 새 Maps Geocoding") {
                    Link("Maps 안내·신청", destination: URL(string: "https://www.ncloud.com/product/applicationService/maps")!)
                    Text("콘솔에서 Application Services → Maps → Application 등록으로 들어가 Geocoding만 선택하세요. HUB 검색 키와는 다른 키입니다.").font(.caption)
                    LabeledContent("Application 이름") { Text("DeliveryRoute-Maps").textSelection(.enabled) }
                    Text("Geocoding만 사용하면 Web URL·Android 패키지·iOS Bundle ID 등록은 필요하지 않습니다. 지도 SDK를 추가해 iOS ID 입력이 필요하다면 아래 값을 사용하세요.").font(.caption)
                    Text("kr.deliverytools.routeprobe").font(.caption.monospaced()).textSelection(.enabled)
                    if api.hasMapsKeys {
                        Label("Maps API 키 저장됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    SecureField(api.hasMapsKeys ? "Client ID · 변경 시 입력" : "Maps Client ID", text: $mapsID)
                    SecureField(api.hasMapsKeys ? "Client Secret · 변경 시 입력" : "Maps Client Secret", text: $mapsSecret)
                    Toggle("이 계정이 Maps 무료 이용 대표 계정임을 확인", isOn: $freeConfirmed)
                    Text("월 300만 건 무료 제공은 대표 계정 하나에 적용됩니다. 확인 전에는 Maps 호출을 차단합니다. 초과분은 유료이므로 외부 사용 횟수도 반영해 주세요.").font(.caption)
                }
                Section {
                    Text("빈 칸은 기존 키를 유지합니다. 앱을 삭제하지 않고 업데이트하면 키와 사용량을 자동으로 불러옵니다. 키를 바꿔도 이전 사용량 기록은 남습니다. Maps 무료 한도 기록은 앱별 키 사이에서도 공유합니다.").font(.caption).foregroundColor(.secondary)
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
