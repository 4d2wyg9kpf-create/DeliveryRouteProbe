import SwiftUI
import MapKit

struct LocationAnalysisScreen: View {
    @EnvironmentObject private var sites: SiteTargetStore
    @ObservedObject var store: PublicDataStore
    let openNaver: () -> Void
    @State private var showSettings = false
    @State private var deleting: SiteTarget?
    @State private var confirmDelete = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { DaejeonNewLicensesView(store: store) } label: {
                        Label("대전 신규 인허가 · 영업 목록", systemImage: "calendar.badge.plus")
                    }
                    Text("일반음식점·휴게음식점·제과점·위탁급식·집단급식소를 인허가일자별로 확인합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("평가대상지 · \(sites.records.count)곳") {
                    Button("네이버검색에서 평가대상지 추가", action: openNaver)
                    Text("네이버검색의 저장할 곳을 ‘입지 평가대상지 목록’으로 선택하세요. 장소를 누르면 주변의 영업 중인 상가 자료를 조회합니다.").font(.caption).foregroundStyle(.secondary)
                    if sites.records.isEmpty { Text("등록된 평가대상지가 없습니다.").foregroundStyle(.secondary) }
                    ForEach(sites.records) { site in
                        HStack {
                            NavigationLink { NearbyBusinessesView(site: site, store: store) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(site.name).bold()
                                    Text(site.address).font(.caption).foregroundStyle(.secondary)
                                    Text("경도 \(site.coordinate.longitude, specifier: "%.6f") · 위도 \(site.coordinate.latitude, specifier: "%.6f")").font(.caption2).foregroundStyle(.secondary)
                                    if !site.folders.isEmpty { Text(site.folders.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            Button(role: .destructive) { deleting = site; confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("\(site.name) 평가대상지 삭제")
                        }
                    }
                    if let error = sites.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("입지 평가") {
                    Text("현재는 평가대상지와 주변 업체를 확인합니다. 평가 항목·점수·비교 방법은 추후 단계별로 추가합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section { Button("공공데이터 API 설정") { showSettings = true } }
            }.navigationTitle("입지분석").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("공공데이터 API 설정") } }
                .sheet(isPresented: $showSettings) { PublicDataSettingsView(store: store) }
                .confirmationDialog("평가대상지 삭제", isPresented: $confirmDelete, titleVisibility: .visible) {
                    if let deleting { Button("\(deleting.name) 삭제", role: .destructive) { do { try sites.remove(deleting.id) } catch { sites.errorMessage = error.localizedDescription } } }
                } message: { Text("이 앱의 평가대상지 목록에서 삭제합니다.") }
        }
    }
}

struct NearbyBusinessesView: View {
    let site: SiteTarget
    @ObservedObject var store: PublicDataStore
    @State private var radius = 500
    @State private var keyword = ""
    @State private var foodOnly = false
    @State private var result: PublicNearbyResult?
    @State private var error: String?
    @State private var loading = false
    @State private var queryTask: Task<Void, Never>?
    @State private var showSettings = false
    private var filtered: [PublicBusiness] {
        (result?.records ?? []).filter { business in
            (!foodOnly || business.categoryCode == "I2") && (keyword.isEmpty || (business.name + business.category + business.address).localizedCaseInsensitiveContains(keyword))
        }
    }
    var body: some View {
        List {
            Section("평가대상지") {
                Text(site.name).bold(); Text(site.address).font(.caption)
                Picker("주변 반경", selection: $radius) { ForEach([100, 300, 500, 1000, 2000], id: \.self) { Text("\($0)m").tag($0) } }.disabled(loading)
                Text("직선거리 기준 · 최대 2km").font(.caption).foregroundStyle(.secondary)
                Button(loading ? "주변 업체 조회 중…" : "주변 운영 업체 조회") { load() }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                if loading { ProgressView(); Text(store.progress).font(.caption); Button("조회 중단") { queryTask?.cancel() } }
                if !store.hasKey || !store.approved.contains(PublicDataService.stores.rawValue) { Button("상가정보 API 설정·활용신청") { showSettings = true } }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if let result {
                Section(result.complete ? "조회 결과" : "일부 조회 결과 · 전체 목록 아님") {
                    Text("조회 반경 \(result.radius)m · 확인된 업체 \(result.records.count)곳 · 표시 \(filtered.count)곳").bold()
                    Text("조회 \(publicTimestamp(result.fetchedAt))").font(.caption)
                    let months = Set(result.records.map(\.referenceMonth).filter { !$0.isEmpty }).sorted()
                    if !months.isEmpty { Text("자료 기준년월 \(months.joined(separator: ", "))").font(.caption) }
                    if result.skipped > 0 { Text("좌표 미제공·반경 밖 자료 \(result.skipped)건 제외").font(.caption).foregroundStyle(.orange) }
                    if radius != result.radius { Text("반경을 변경했습니다. 다시 조회하세요.").font(.caption).foregroundStyle(.orange) }
                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption).foregroundStyle(.orange) }
                    NativeTextField("업체명 · 업종 · 주소에서 찾기", text: $keyword).frame(minHeight: 44)
                    Toggle("음식점업만 표시", isOn: $foodOnly)
                    Text("소상공인시장진흥공단의 영업 중인 상가 자료입니다. 실제 휴·폐업 반영에는 시차가 있어 현장 확인이 필요합니다.").font(.caption).foregroundStyle(.secondary)
                }
                if filtered.isEmpty { Text(result.complete ? "이 조건으로 확인된 업체가 없습니다." : "조회가 완료되지 않았습니다. 오류를 확인하고 다시 조회하세요.").foregroundStyle(.secondary) }
                ForEach(filtered) { business in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(business.name).bold(); Spacer(); Text("\(business.distanceMeters, specifier: "%.0f")m").font(.caption) }
                        Text(business.category).font(.caption).foregroundStyle(.secondary)
                        Text(business.address).font(.caption).textSelection(.enabled)
                        Text("경도 \(business.longitude, specifier: "%.6f") · 위도 \(business.latitude, specifier: "%.6f")").font(.caption2).foregroundStyle(.secondary)
                        if let url = naverAddressURL(business.name, business.address) { Link("네이버에서 확인", destination: url).font(.caption) }
                    }
                }
            }
        }.navigationTitle("주변 업체").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { PublicDataSettingsView(store: store) }
            .onDisappear { queryTask?.cancel() }
    }
    private func load() {
        loading = true; error = nil; result = nil
        let requestedRadius = radius
        queryTask = Task {
            defer { loading = false; queryTask = nil }
            do { result = try await store.nearby(center: site.coordinate, radius: requestedRadius) }
            catch is CancellationError { error = "조회를 중단했습니다. 요청한 횟수는 사용량에 포함합니다." }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct DaejeonNewLicensesView: View {
    @ObservedObject var store: PublicDataStore
    @State private var fromDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State private var throughDate = Date()
    @State private var selected = Set(PublicDataService.licenses)
    @State private var keyword = ""
    @State private var result: PublicSalesResult?
    @State private var error: String?
    @State private var loading = false
    @State private var showSettings = false
    @State private var queryTask: Task<Void, Never>?
    private var records: [PublicLicense] { (result?.records ?? []).filter { keyword.isEmpty || ($0.name + $0.address + $0.service.title).localizedCaseInsensitiveContains(keyword) } }
    private var days: [String] { Set(records.map(\.permissionDate)).sorted(by: >) }
    var body: some View {
        List {
            Section("대전 신규 인허가 · 인허가일자 기준") {
                DatePicker("시작일", selection: $fromDate, displayedComponents: .date).disabled(loading)
                DatePicker("종료일 · 포함", selection: $throughDate, displayedComponents: .date).disabled(loading)
                ForEach(PublicDataService.licenses) { service in
                    Toggle(service.title, isOn: Binding(get: { selected.contains(service) }, set: { if $0 { selected.insert(service) } else { selected.remove(service) } })).disabled(loading)
                }
                Button(loading ? "인허가 조회 중…" : "일자별 신규 업소 조회") { load() }.buttonStyle(.borderedProminent).disabled(store.isBusy || selected.isEmpty || fromDate > throughDate)
                if loading { ProgressView(); Text(store.progress).font(.caption); Button("조회 중단") { queryTask?.cancel() } }
                Button("인허가 API 5개 활용신청·키 설정") { showSettings = true }.disabled(loading)
                Text("대전광역시와 5개 구의 선택한 업종을 조회하고, 현재 영업/정상 상태인 자료를 표시합니다. 날짜는 인허가일이며 실제 개업일·사업자등록일과 다를 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if let result {
                Section(result.complete ? "조회 현황" : "일부 조회 · 업종·지역 누락 있음") {
                    Text("\(result.from) ~ \(result.through) · \(result.records.count)곳").bold()
                    Text("조회 \(publicTimestamp(result.fetchedAt)) · \(result.services.map(\.title).joined(separator: " · "))").font(.caption)
                    Text("인허가 정보는 매일 갱신되며 2일 전 기준으로 현행화됩니다. 신고·갱신이 늦으면 최신 업소가 누락될 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption).foregroundStyle(.orange) }
                    NativeTextField("업소명 · 주소 · 업종에서 찾기", text: $keyword).frame(minHeight: 44)
                    if records.isEmpty { Text(result.complete ? "해당 기간·조건으로 확인된 업소가 없습니다." : "조회가 완료되지 않았습니다. 승인·오류 상태를 확인하세요.").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(days, id: \.self) { day in
                    Section("\(day) · \(records.filter { $0.permissionDate == day }.count)곳") {
                        ForEach(records.filter { $0.permissionDate == day }) { business in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(business.name).bold().textSelection(.enabled)
                                Text("\(business.service.title) · \(business.status)").font(.caption).foregroundStyle(.secondary)
                                Text(business.address.isEmpty ? "주소 미제공" : business.address).font(.caption).textSelection(.enabled)
                                if !business.phone.isEmpty { Text("전화 \(business.phone)").font(.caption).textSelection(.enabled) }
                                if !business.updatedAt.isEmpty { Text("자료 갱신 \(business.updatedAt)").font(.caption2).foregroundStyle(.secondary) }
                                if let url = naverAddressURL(business.name, business.address) { Link("네이버에서 확인", destination: url).font(.caption) }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("대전 신규 인허가").navigationBarTitleDisplayMode(.inline)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!)
            .sheet(isPresented: $showSettings) { PublicDataSettingsView(store: store) }
            .onDisappear { queryTask?.cancel() }
    }
    private func load() {
        loading = true; result = nil; error = nil
        let services = PublicDataService.licenses.filter { selected.contains($0) }
        let from = publicDay(fromDate), through = publicDay(throughDate)
        queryTask = Task {
            defer { loading = false; queryTask = nil }
            do { result = try await store.newDaejeonLicenses(from: from, through: through, services: services) }
            catch is CancellationError { error = "조회를 중단했습니다. 요청한 횟수는 사용량에 포함합니다." }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct PublicDataSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject var store: PublicDataStore
    @State private var key = ""
    @State private var approved: Set<String> = []
    @State private var limits: [String: Int] = [:]
    var body: some View {
        NavigationStack {
            Form {
                Section("공공데이터포털 인증키") {
                    if store.hasKey { Label("인증키 저장됨 · 업데이트 시 유지", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    SecureField(store.hasKey ? "인증키 변경 시에만 입력" : "일반 인증키 · Decoding 권장", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("기관이 같아도 API 서비스별로 활용신청합니다. 같은 서비스의 여러 조회 기능은 해당 신청에 포함됩니다. 동일한 개인·프로젝트 서비스키로 승인받은 항목은 아래 키를 함께 사용합니다. 빈 칸으로 저장하면 기존 키를 유지합니다.").font(.caption)
                }
                ForEach(PublicDataService.allCases) { service in
                    Section(service == .stores ? "소상공인시장진흥공단 · 주변 업체" : "행정안전부 · \(service.title)") {
                        Link("\(service.title) 활용신청", destination: service.portalURL)
                        Toggle("이 서비스의 활용승인·무료 제공 확인", isOn: Binding(get: { approved.contains(service.rawValue) }, set: { if $0 { approved.insert(service.rawValue) } else { approved.remove(service.rawValue) } }))
                        NumberRow(title: "포털에 승인된 일일 한도", value: Binding(get: { limits[service.rawValue] ?? 10_000 }, set: { limits[service.rawValue] = $0 }))
                        if let quota = store.quotas.first(where: { $0.id == service }) {
                            Text("이 기기 기록 \(quota.used.formatted())회 · 잔여 \(quota.remaining.formatted())회").font(.caption)
                            if let reset = quota.resetAt { Text("앱 초기화 대기 종료 \(publicTimestamp(reset))").font(.caption2) }
                            if quota.blocked { Text("한도 소진·서버 차단·초기화 대기").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                Section {
                    Button("잔여량 기준 시각 새로 확인") { Task { await store.refreshClock() } }.disabled(store.isBusy)
                    Text("공식 개발계정 기본 한도는 서비스별 10,000회입니다. 한 번의 조회가 여러 페이지·지역을 요청할 수 있습니다. 실패·중단도 기록하고 한도 소진 시 차단합니다. 일 초기화는 한국시간 0시, 앱 재개는 5분 뒤를 기준으로 하며 서버가 계속 제한하면 다시 차단합니다. 다른 기기의 사용량은 자동 동기화되지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }.navigationTitle("공공데이터 API 설정").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { inputs.finishEditing(); dismiss() }.disabled(store.isBusy) }
                    ToolbarItem(placement: .confirmationAction) { Button("저장") { inputs.finishEditing(); if store.saveSettings(key: key, approved: approved, limits: limits) { dismiss() } }.disabled(store.isBusy) }
                }
                .onAppear { approved = store.approved; limits = Dictionary(uniqueKeysWithValues: PublicDataService.allCases.map { ($0.rawValue, store.limit($0)) }) }
        }
    }
}

private func publicDay(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Seoul"); f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}
private func publicTimestamp(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.timeZone = TimeZone(identifier: "Asia/Seoul"); f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}
private func naverAddressURL(_ name: String, _ address: String) -> URL? {
    let text = (name + " " + address).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let escaped = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
    return URL(string: "https://map.naver.com/p/search/" + escaped)
}
