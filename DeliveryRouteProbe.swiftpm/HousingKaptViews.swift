import SwiftUI

struct HousingIntegrationView: View {
    @EnvironmentObject private var inputs: NativeInputSession
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
                Button("주소 API 승인키 저장") { do { inputs.finishEditing(); try store.saveAddressKey(key); key = "" } catch { self.error = error.localizedDescription } }.disabled(store.isBusy)
                Link("도로명주소 API 신청",destination:URL(string:"https://business.juso.go.kr/")!)
                Text("주소 API의 상세 건물명은 주소 전체의 동 목록입니다. 관리사무소별 소속 동과 비교할 참고 자료로 보존합니다. 주소만으로 자동 통합하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("수집 범위") {
                Picker("보관된 법정동",selection:$regionCode) {
                    Text("선택").tag("")
                    ForEach(store.regions) { Text($0.title).tag($0.code) }
                }.disabled(store.isBusy)
                Button("선택 법정동 K-apt 수집 이어서") { collect(all:false,refresh:false) }.disabled(regionCode.isEmpty || store.isBusy)
                Button("선택 법정동 K-apt 기존 상세까지 다시 수집") { collect(all:false,refresh:true) }.disabled(regionCode.isEmpty || store.isBusy)
                Button("보관된 모든 법정동 K-apt 수집 이어서") { collect(all:true,refresh:false) }.disabled(store.regions.isEmpty || store.isBusy)
                Button("선택 법정동 주소·주민센터 확인 이어서") { start { try await store.collectAddresses(regionCode) } }.disabled(regionCode.isEmpty || !store.hasAddressKey || store.isBusy)
                Text("공시가격 단지가 보관된 지역을 보정합니다. K-apt에 없는 공동주택은 유지하며, K-apt에만 있는 등록은 평가 목록에 자동 추가하지 않습니다. 기본 수집은 새 등록·상세 미완료 항목만 상세 조회합니다. 수집만으로 단지를 합치거나 K-apt를 연결하지 않습니다. 직접 검토해 적용한 연결과 사용자 가공을 공유 폴더로 동기화합니다.").font(.caption).foregroundStyle(.secondary)
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
            do { store.collectionProgress = nil; try await work(); store.progress = "수집 원본을 저장했습니다. 연결과 통합은 직접 검토한 뒤 적용하세요." }
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
    @EnvironmentObject private var inputs: NativeInputSession
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
                    do { inputs.finishEditing(); let changed = fields.filter { source.fields[$0.key,default:""] != $0.value }; try store.saveSourceOverride(source,fields:changed,confirmedDongs:confirmedDongs,excluded:excluded) } catch { self.error = error.localizedDescription }
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
                confirmedDongs = edit?.dongScopeConfirmed ?? source.dongScopeConfirmed ?? false; excluded = edit?.sourceExcluded ?? false
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
    @State private var useWholeName = false
    @State private var keyword = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("연결할 K-apt 등록") {
                    NativeTextField("K-apt 단지명 · 주소 검색",text:$keyword)
                    Text("주소·동 번호·승인일과 실제 관리 범위를 확인하여 선택하세요. 둔산이편한세상처럼 전체와 부분 등록이 겹치면 전체 등록을 대표로 선택합니다. 부분 등록은 별도 평가대상으로 추가되지 않습니다.").font(.caption)
                    ForEach(Array(sources.filter { keyword.isEmpty || $0.fields.values.joined(separator:" ").localizedCaseInsensitiveContains(keyword) }.prefix(500))) { source in
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
                    Toggle("선택한 전체 등록의 단지명으로 변경",isOn:$useWholeName)
                    Text("이름 변경을 선택하지 않으면 직접 수정한 단지명을 유지합니다.").font(.caption)
                    Button("확인한 K-apt 연결 적용") { do { try store.attachKapt(complex,sourceIDs:selected,wholeID:wholeID.isEmpty ? nil : wholeID,useWholeName:useWholeName); dismiss() } catch { self.error = error.localizedDescription } }
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

struct HousingMergeReviewView: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @EnvironmentObject private var store: HousingStore
    @Environment(\.dismiss) private var dismiss
    let complex: HousingComplex
    @State private var candidates: [HousingComplex] = []
    @State private var selected = Set<String>()
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("주소 기반 후보 · 직접 확인") {
                    Text("같은 도로명주소·대표지번 또는 확인된 관리사무소를 가진 보관 단지입니다. 주소가 같다는 이유로 자동 선택하거나 통합하지 않습니다.").font(.caption)
                    Text("동 번호가 101·102·103동처럼 같은 앞자리에서 이어지는지 확인하세요. 201동처럼 앞자리가 다르거나 소속 동이 불명확한 단지는 구분해서 검토합니다.").font(.caption)
                    Text("주소가 다른 단지는 공동주택 목록에서 검색해 직접 함께 선택할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    ForEach(candidates) { candidate in
                        HStack(alignment:.top) {
                            Button { if !selected.insert(candidate.id).inserted { selected.remove(candidate.id) } } label: { Image(systemName:selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless)
                            HousingMergeCandidateRow(complex:candidate)
                        }
                    }
                    if candidates.count < 2 { Text("현재 보관 자료에서 같은 주소의 다른 단지가 없습니다.").font(.caption) }
                }
                Section("확인한 단지 통합") {
                    NativeTextField("통합 후 단지명",text:$name)
                    Text("원본별 주소·동·세부 값과 수정 기록을 보존합니다. 범위를 확인할 수 없는 주차·세대·승강기 합계는 빈칸으로 두고 직접 보정합니다. 나중에 상세를 다시 받아도 연결과 수정값을 유지합니다.").font(.caption)
                    Button("직접 확인한 \(selected.count)개를 통합") {
                        do { inputs.finishEditing(); let latest = try store.reviewCandidates(complex); try store.merge(selected,name:name,reviewed:latest); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(selected.count < 2 || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || store.isBusy)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("통합 후보 확인").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("닫기") { dismiss() } } }
                .onAppear { do { candidates = try store.reviewCandidates(complex); selected = [complex.id]; name = complex.name } catch { self.error = error.localizedDescription } }
        }
    }
}

private struct HousingMergeCandidateRow: View {
    let complex: HousingComplex
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(complex.name)
            Text(complex.fields["roadAddress"] ?? "도로명주소 미수집").font(.caption)
            Text(complex.fields["jibunAddress"] ?? "지번주소 미수집").font(.caption)
            Text("동 번호: \(complex.fields["dongNames",default:"미확인"])").font(.caption)
            Text("관리사무소: \(complex.fields["managementOffice",default:"미확인"])").font(.caption)
            Text("사용승인: \(complex.fields["approvalDate",default:"미확인"]) · \(complex.fields["buildings",default:"?"])동 · \(complex.fields["households",default:"?"])세대").font(.caption)
            DisclosureGroup("원본별 범위·정보 비교") {
                ForEach(complex.originals) { source in
                    VStack(alignment:.leading) {
                        Text((source.isKapt ? "K-apt · " : "공시가격 · ") + (source.fields["name"] ?? source.aptCode)).font(.caption)
                        Text("\(source.aptCode) · \(source.fields["dongNames",default:"소속 동 미확인"])").font(.caption2)
                        Text(source.fields["roadAddress"] ?? "").font(.caption2)
                        Text(source.fields["jibunAddress"] ?? "").font(.caption2)
                        Text("관리사무소: \(source.fields["managementOffice",default:"미확인"])").font(.caption2)
                        NavigationLink("원본 세부 값·소속 동 보정") { HousingSourceEditView(source:source) }
                    }
                }
            }
        }.textSelection(.enabled)
    }
}
