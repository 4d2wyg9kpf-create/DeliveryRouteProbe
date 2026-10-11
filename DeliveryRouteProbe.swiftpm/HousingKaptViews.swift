import SwiftUI

struct HousingIntegrationView: View {
    @EnvironmentObject private var store: HousingStore
    @ObservedObject private var api = PublicDataStore.shared
    @State private var regionCode: String
    @State private var key = ""
    @State private var showingSettings = false
    @State private var keyword = ""
    @State private var sources: [HousingSource] = []
    @State private var job: Task<Void,Never>?
    @State private var error: String?
    init(regionCode: String = "") { _regionCode = State(initialValue:regionCode) }
    private var filtered: [HousingSource] { sources.filter { keyword.isEmpty || $0.fields.values.joined(separator:" ").localizedCaseInsensitiveContains(keyword) } }
    var body: some View {
        List {
            Section("K-apt 수집 설정") {
                Button("공공데이터 키 · K-apt 활용승인 설정") { showingSettings = true }
                ForEach(api.quotas.filter { $0.id == .kaptList || $0.id == .kaptBasis }) { q in
                    Text("\(q.id.title) · \(q.remaining.formatted())/\(q.limit.formatted())회 남음").font(.caption)
                }
                Text("단지 목록 제공 서비스와 기본 정보제공 서비스를 각각 활용신청하세요. 기본·관리시설정보는 같은 서비스 한도를 사용합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("주소 확인 · 관할 주민센터") {
                NativeTextField(store.hasAddressKey ? "승인키 변경 시에만 입력" : "도로명주소 API 승인키",text:$key,keyboard:.asciiCapable,secure:true)
                Button("주소 API 승인키 저장") { do { try store.saveAddressKey(key); key = "" } catch { self.error = error.localizedDescription } }.disabled(store.isBusy)
                Link("도로명주소 API 신청",destination:URL(string:"https://business.juso.go.kr/")!)
                Text("주소 API의 상세 건물명은 주소 전체의 동 목록입니다. 관리사무소별 소속 동이 확인되기 전에는 자동 통합 근거로 확정하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("수집 범위") {
                Picker("보관된 법정동",selection:$regionCode) {
                    Text("선택").tag("")
                    ForEach(store.regions) { Text($0.title).tag($0.code) }
                }.disabled(store.isBusy)
                Button("선택 법정동 K-apt 수집·통합 이어서") { collect(all:false,refresh:false) }.disabled(regionCode.isEmpty || store.isBusy)
                Button("선택 법정동 K-apt 최신 정보 다시 수집") { collect(all:false,refresh:true) }.disabled(regionCode.isEmpty || store.isBusy)
                Button("보관된 모든 법정동 K-apt 수집·통합 이어서") { collect(all:true,refresh:false) }.disabled(store.regions.isEmpty || store.isBusy)
                Button("선택 법정동 주소·주민센터 확인 이어서") { start { try await store.collectAddresses(regionCode) } }.disabled(regionCode.isEmpty || !store.hasAddressKey || store.isBusy)
                Text("공시가격 단지가 보관된 지역을 보정합니다. K-apt에 없는 공동주택은 유지하며, K-apt에만 있는 등록은 평가 목록에 자동 추가하지 않습니다. 완료한 자료와 사용자 가공은 공유 폴더로 동기화합니다.").font(.caption).foregroundStyle(.secondary)
                if store.isBusy { ProgressView(); Text(store.progress).font(.caption); Button("수집 중단") { job?.cancel() } }
                if let error = error ?? store.errorMessage ?? api.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                NavigationLink("기기 간 공유 폴더 설정") { DeviceSharingSettingsView() }
            }
            Section("K-apt 원본 · \(sources.count)건") {
                NativeTextField("단지명 · 주소 · 관리사무소에서 검색",text:$keyword)
                Text("도로명주소·지번·사용승인일·규모로 동일성을 확인합니다. 같은 주소에 여러 등록이 있거나 범위가 불명확하면 각 단지의 ‘K-apt 연결·전체 단지 선택’에서 검토하세요.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(filtered.prefix(500))) { source in
                    NavigationLink { HousingSourceEditView(source:source) } label: {
                        VStack(alignment:.leading) {
                            Text(source.fields["name"] ?? source.aptCode)
                            Text(source.fields["roadAddress"] ?? "상세 미수집").font(.caption)
                            Text("\(source.aptCode) · \(source.fields["buildings",default:"?"])동 · \(source.fields["households",default:"?"])세대 · \(source.fields["registrationStatus",default:"미확인"])").font(.caption2).foregroundStyle(.secondary)
                            if store.edits.first(where: { $0.id == source.id })?.hidden == true { Text("사용자 제외 · 재수집 시 유지").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                if filtered.count > 500 { Text("500건까지 표시합니다. 검색어로 좁히세요.").font(.caption) }
            }
        }.navigationTitle("K-apt 수집·단지 통합").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showingSettings) { PublicDataSettingsView(store:api) }
            .onAppear { if regionCode.isEmpty { regionCode = store.regions.first?.code ?? "" }; reload() }
            .onChange(of:regionCode) { _,_ in reload() }
            .onChange(of:store.regions.first { $0.code == regionCode }?.generation) { _,_ in reload() }
            .onDisappear { job?.cancel() }
    }
    private func reload() { do { sources = regionCode.isEmpty ? [] : try store.originalRegion(regionCode).kaptRecords ?? [] } catch { self.error = error.localizedDescription } }
    private func start(_ work: @escaping () async throws -> Void) {
        guard !store.isBusy else { return }; store.isBusy = true; error = nil
        job = Task {
            defer { store.isBusy = false; job = nil; reload() }
            do { try await work(); store.progress = "수집·통합 자료를 저장했습니다." }
            catch is CancellationError { store.progress = "중단했습니다. 완료된 자료에서 이어서 수집할 수 있습니다." }
            catch { self.error = error.localizedDescription }
        }
    }
    private func collect(all: Bool, refresh: Bool) {
        let codes = all ? store.regions.map(\.code) : [regionCode]
        start { for code in codes { try Task.checkCancellation(); try await store.collectKapt(code,refresh:refresh,api:api) } }
    }
}

struct HousingSourceEditView: View {
    @EnvironmentObject private var store: HousingStore
    let source: HousingSource
    @State private var fields: [String:String] = [:]
    @State private var confirmedDongs = false
    @State private var excluded = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("원본별 보정 · 재수집 시 유지") {
                ForEach(HousingField.allCases.filter { !$0.derived }) { field in
                    VStack(alignment:.leading) {
                        Text(field.title).font(.caption).foregroundStyle(.secondary)
                        NativeTextField(field.title,text:Binding(get:{ fields[field.rawValue] ?? "" },set:{ fields[field.rawValue] = $0 }))
                    }
                }
                Toggle("입력한 동 번호가 이 등록의 실제 소속 동 전체임을 확인",isOn:$confirmedDongs)
                Text("101·102·103동처럼 앞자리가 같고 연속되어야 연결됩니다. 주소 API에서 보인 전체 동을 부분 단지의 소속 동으로 그대로 확정하지 마세요.").font(.caption)
                Toggle("사용자 확인으로 통합·평가에서 제외",isOn:$excluded)
                Text("철거·멸실 또는 중복 등록을 확인한 경우에 지정합니다. K-apt 사용 중지 표시는 실제 멸실을 뜻하지 않습니다.").font(.caption)
                Button("원본별 보정 저장") {
                    do { let changed = fields.filter { source.fields[$0.key,default:""] != $0.value }; try store.saveSourceOverride(source,fields:changed,confirmedDongs:confirmedDongs,excluded:excluded) } catch { self.error = error.localizedDescription }
                }
            }
            Section("수집 원본 · \(source.aptCode)") {
                ForEach(HousingField.allCases) { f in LabeledContent(f.title,value:source.fields[f.rawValue] ?? "미수집") }
                HousingAddressEvidenceView(source:source)
                ForEach(Array(source.issues.enumerated()),id:\.offset) { _,issue in Text(issue).font(.caption).foregroundStyle(.orange) }
                if let at = source.detailAt { Text("수집: \(at.formatted(date:.numeric,time:.shortened))").font(.caption) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(source.fields["name"] ?? "원본별 보정").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let edit = store.edits.first { $0.id == source.id }; fields = source.fields; fields.merge(edit?.fields ?? [:]) { _,user in user }
                confirmedDongs = edit?.dongScopeConfirmed ?? source.dongScopeConfirmed ?? false; excluded = edit?.hidden ?? false
            }
    }
}

struct HousingAddressEvidenceView: View {
    let source: HousingSource
    var body: some View {
        ForEach(Array((source.addresses ?? []).enumerated()),id:\.offset) { _,evidence in
            VStack(alignment:.leading) {
                Text("주소 API: \(evidence.roadAddress)").font(.caption)
                Text("관할 주민센터: \(evidence.communityCenter.isEmpty ? "미제공" : evidence.communityCenter)").font(.caption)
                Text("주소 전체의 상세 건물명: \(evidence.dongNames.joined(separator:", "))").font(.caption)
                Text("건물관리번호: \(evidence.buildingID)").font(.caption2).foregroundStyle(.secondary)
            }.textSelection(.enabled)
        }
    }
}

struct HousingKaptLinkView: View {
    @EnvironmentObject private var store: HousingStore
    @Environment(\.dismiss) private var dismiss
    let complex: HousingComplex
    @State private var sources: [HousingSource] = []
    @State private var selected = Set<String>()
    @State private var wholeID = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("연결할 K-apt 등록") {
                    Text("주소·동 번호·승인일과 실제 관리 범위를 확인하여 선택하세요. 둔산이편한세상처럼 전체와 부분 등록이 겹치면 전체 등록을 대표로 선택합니다. 부분 등록은 별도 평가대상으로 추가되지 않습니다.").font(.caption)
                    ForEach(sources) { source in
                        HStack(alignment:.top) {
                            Button { if !selected.insert(source.id).inserted { selected.remove(source.id); if wholeID == source.id { wholeID = "" } } } label: { Image(systemName:selected.contains(source.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless)
                            NavigationLink { HousingSourceEditView(source:source) } label: {
                                VStack(alignment:.leading) {
                                    Text(source.fields["name"] ?? source.aptCode)
                                    Text(source.fields["roadAddress"] ?? "").font(.caption)
                                    Text("\(source.fields["approvalDate",default:"?"]) · \(source.fields["buildings",default:"?"])동 · \(source.fields["households",default:"?"])세대").font(.caption2)
                                    Text(source.fields["dongNames"] ?? "소속 동 번호 미확인").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("전체·부분 범위 중복 처리") {
                    Picker("전체 단지 등록으로 사용할 원본",selection:$wholeID) {
                        Text("확인된 동 범위로 집계").tag("")
                        ForEach(sources.filter { selected.contains($0.id) }) { Text($0.fields["name"] ?? $0.aptCode).tag($0.id) }
                    }
                    Text("전체 등록을 선택하면 그 주차·승강기 수치를 사용하고 부분 등록 수치를 다시 더하지 않습니다. 서로 다른 세부 값과 원본은 모두 보존합니다. 전체 등록이 실제 평가범위와 일치하는지 확인하세요.").font(.caption)
                    Button("연결·통합 적용") { do { try store.attachKapt(complex,sourceIDs:selected,wholeID:wholeID.isEmpty ? nil : wholeID); dismiss() } catch { self.error = error.localizedDescription } }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("K-apt 연결·전체 단지 선택").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("닫기") { dismiss() } } }
                .onAppear {
                    do {
                        let regions = Set(complex.originals.map(\.regionCode)).union([complex.regionCode])
                        sources = try regions.flatMap { try store.originalRegion($0).kaptRecords ?? [] }.sorted { a,b in
                            let am = complex.originals.contains { HousingIdentity.sameRoad($0,a) }, bm = complex.originals.contains { HousingIdentity.sameRoad($0,b) }
                            return am != bm ? am : (a.fields["name"] ?? "") < (b.fields["name"] ?? "")
                        }
                        selected = Set(complex.sourceIDs.filter { $0.hasPrefix("kapt:") }); wholeID = store.edits.first { $0.id == complex.id }?.preferredKaptID ?? ""
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
}
