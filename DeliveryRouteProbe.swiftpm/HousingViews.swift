import SwiftUI
import UniformTypeIdentifiers

struct DataTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }
    var text: String
    init(_ text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
struct HousingCatalogView: View {
    @EnvironmentObject private var store: HousingStore
    @EnvironmentObject private var sites: SiteTargetStore
    @State private var sidos: [HousingArea] = []
    @State private var districts: [HousingArea] = []
    @State private var dongs: [HousingArea] = []
    @State private var sido = ""
    @State private var district = ""
    @State private var dong = ""
    @State private var keyword = ""
    @State private var selected = Set<String>()
    @State private var merging = false
    @State private var mergeName = ""
    @State private var adding = false
    @State private var newName = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var document = DataTextDocument()
    @State private var error: String?
    private let client = RealtyHousingClient()
    private var regionCode: String { sido + district + dong }
    private var selectedCollectionScope: HousingCollectionScope? {
        guard let s = sidos.first(where: { $0.code == sido }) else { return nil }
        guard !district.isEmpty else { return .province(s) }
        guard let g = districts.first(where: { $0.code == district }) else { return nil }
        guard !dong.isEmpty else { return .district(s, g) }
        guard let d = dongs.first(where: { $0.code == dong }) else { return nil }
        return .dong(s, g, d)
    }
    private var filtered: [HousingComplex] {
        store.complexes.filter { item in
            (dong.isEmpty || item.regionCode == regionCode || item.originals.contains { $0.regionCode == regionCode }) && (keyword.isEmpty || item.searchText.localizedCaseInsensitiveContains(keyword))
        }
    }
    var body: some View {
        let rows = filtered
        List {
            Section("공동주택 찾기") {
                NativeTextField("단지명 · 도로명주소 · 지번주소 검색", text: $keyword)
                Picker("시도", selection: $sido) { Text("선택").tag(""); ForEach(sidos) { Text($0.name).tag($0.code) } }.disabled(store.isBusy)
                Picker("시군구", selection: $district) { Text("선택").tag(""); ForEach(districts) { Text($0.name).tag($0.code) } }.disabled(store.isBusy)
                Picker("법정동 · 리", selection: $dong) { Text("전체 보관 자료").tag(""); ForEach(dongs) { Text($0.name).tag($0.code) } }.disabled(store.isBusy)
                Text("보관 지역 \(store.regions.count)곳 · 원본 \(store.regions.reduce(0) { $0 + $1.sourceCount })건 · 표시 \(rows.count)건").font(.caption)
                Text("전국 수집 완료 여부는 보관 지역별로 확인하세요. 검색 결과는 최대 2,000건을 읽습니다. 미수집 지역과 상세 미수집 항목은 빈칸으로 표시합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("원본 수집 · 공유") {
                NavigationLink("K-apt 정보 수집·단지 통합") { HousingIntegrationView(regionCode:dong.isEmpty ? "" : regionCode) }.disabled(store.isBusy)
                Button("\(selectedCollectionScope?.buttonPrefix ?? "선택 지역") 신규단지 목록 확인") { collect(details: false) }.disabled(selectedCollectionScope == nil || store.isBusy)
                Button("\(selectedCollectionScope?.buttonPrefix ?? "선택 지역") 신규단지 추가·미완료 상세 수집") { collect(details: true) }.disabled(selectedCollectionScope == nil || store.isBusy)
                Button("전국 신규단지 추가·미완료 상세 수집") { collectNational() }.disabled(store.isBusy)
                Text("모바일 목록을 확인해 신규 단지를 추가하고 상세 미완료 항목만 수집합니다. 공시 연도가 바뀌어도 기존 상세와 사용자 수정·통합은 유지합니다. 전체 목록 저장에는 2,000건 제한이 없으며, 기존 단지의 최신 상세는 단지 화면에서 직접 수집하세요.").font(.caption).foregroundStyle(.secondary)
                HousingCollectionStatusView(status: store.collectionStatus, busy: store.isBusy)
                if store.isBusy { Button("수집 중단") { store.stopRealtyCollection() } }
                else if let title = store.resumableScopeTitle {
                    Button("\(title) 보관된 수집 이어서 하기") { store.resumeRealtyCollection() }
                }
                Text("전체 단지 목록을 먼저 확인한 후 단지 기준 진행률과 예상 시간을 표시합니다. 앱이 작업을 보관하므로 다른 화면으로 이동해도 계속 수집합니다. 백그라운드 실행은 iOS 26 이상에서 지원하며, 시스템이 중단하면 저장된 작업을 이어서 수집하세요.").font(.caption).foregroundStyle(.secondary)
                Text("시도만 선택하면 해당 시도 전체, 시군구까지만 선택하면 해당 시군구 전체를 수집합니다. 상세 수집은 새 단지와 미완료 단지만 처리합니다.").font(.caption).foregroundStyle(.secondary)
                NavigationLink("기기 간 공유 폴더 설정") { DeviceSharingSettingsView() }
                Button("JSON 자료 가져오기") { importing = true }.disabled(store.isBusy)
                Button("보관 자료·사용자 수정 JSON 내보내기") {
                    do { document = DataTextDocument(String(decoding: try JSONEncoder().encode(HousingExport(regions: try store.exportRegions(dong.isEmpty ? "" : regionCode), edits: store.edits)), as: UTF8.self)); exporting = true } catch { self.error = error.localizedDescription }
                }
                Button("현재 검색 결과 CSV 내보내기") { document = DataTextDocument(housingCSV(store.complexes, regions: store.regions)); exporting = true }
                if let error = error ?? store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if !store.regions.isEmpty {
                Section("수집 현황") {
                    ForEach(store.regions.filter { sido.isEmpty || $0.sido.code == sido }) { region in
                        Text("\(region.title) · 공시가격 \(region.sourceCount) / 상세 \(region.detailCount) · K-apt \(region.kaptDetailCount ?? 0)/\(region.kaptCount ?? 0)").font(.caption)
                    }
                }
            }
            if store.edits.contains(where: \.hidden) {
                Section("숨긴 단지 · 복원") {
                    ForEach(store.edits.filter(\.hidden)) { edit in
                        Button((edit.fields["name"] ?? edit.id) + " · 다시 표시") { do { try store.restore(edit.id) } catch { self.error = error.localizedDescription } }
                    }
                }
            }
            Section("단지 목록 · \(rows.count)건") {
                Button("새 단지 추가") { adding = true }
                if selected.count > 1 { Button("선택한 \(selected.count)개를 하나로 합치기") { merging = true } }
                ForEach(Array(rows.prefix(500))) { complex in
                    HStack {
                        Button { if selected.contains(complex.id) { selected.remove(complex.id) } else { selected.insert(complex.id) } } label: { Image(systemName: selected.contains(complex.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless)
                        NavigationLink { HousingComplexView(complexID: complex.id) } label: {
                            VStack(alignment: .leading) {
                                Text(complex.name); Text(complex.address).font(.caption).foregroundStyle(.secondary)
                                Text(complex.edited ? "사용자 가공 적용" : complex.original?.detailAt == nil ? "목록 수집 · 상세 미수집" : "상세 수집").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if rows.count > 500 { Text("500건까지 표시합니다. 법정동이나 검색어로 범위를 좁히세요.").font(.caption) }
            }
        }.navigationTitle("공동주택 목록").navigationBarTitleDisplayMode(.inline)
            .task { do { sidos = try await client.areas() } catch { self.error = error.localizedDescription; sidos = Array(Set(store.regions.map(\.sido))).sorted { $0.name < $1.name } } }
            .task(id: regionCode + "|" + keyword) { await store.search(region: dong.isEmpty ? "" : regionCode, keyword: keyword) }
            .onChange(of: sido) { _, value in
                district = ""; dong = ""; districts = []; dongs = []
                guard !value.isEmpty else { return }
                Task { do { let rows = try await client.areas(sido: value); if sido == value { districts = rows } } catch { self.error = error.localizedDescription } }
            }
            .onChange(of: district) { _, value in
                dong = ""; dongs = []; guard !value.isEmpty else { return }; let currentSido = sido
                Task { do { let rows = try await client.areas(sido: currentSido, sigungu: value); if sido == currentSido && district == value { dongs = rows } } catch { self.error = error.localizedDescription } }
            }
            .alert("합칠 단지명", isPresented: $merging) {
                TextField("단지명", text: $mergeName)
                Button("합치기") { do { try store.merge(selected, name: mergeName); selected.removeAll() } catch { self.error = error.localizedDescription } }
                Button("취소", role: .cancel) {}
            } message: { Text("모든 원본의 세부 정보를 보존합니다. 범위를 확인할 수 없는 수치는 빈칸으로 남기며, 원본별 정보에서 확인·수정할 수 있습니다.") }
            .alert("새 단지", isPresented: $adding) {
                TextField("단지명", text: $newName)
                Button("추가") { do { _ = try store.add(name: newName, regionCode: dong.isEmpty ? "" : regionCode); newName = "" } catch { self.error = error.localizedDescription } }
                Button("취소", role: .cancel) {}
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    if let region = try? HousingStore.decode(data) { try store.importRegion(region) }
                    else {
                        let bundle = try JSONDecoder().decode(HousingExport.self, from: data); guard bundle.version == 1 else { throw DeviceShareError.invalid }
                        try HousingStore.validate(bundle.edits)
                        for region in bundle.regions { try region.validate() }
                        for region in bundle.regions { try store.importRegion(region) }
                        try store.importEdits(bundle.edits)
                    }
                } catch { self.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: document.text.hasPrefix("{") ? .json : .commaSeparatedText, defaultFilename: "공동주택자료") { result in if case .failure(let failure) = result { error = failure.localizedDescription } }
    }
    private func collect(details: Bool) {
        guard let scope = selectedCollectionScope else { return }
        start(scope: scope, details: details)
    }
    private func start(scope: HousingCollectionScope, details: Bool) {
        error = nil; store.startRealtyCollection(scope: scope, details: details, client: client)
    }
    private func collectNational() { start(scope: .nationwide, details: true) }
}
// Progress/ETA redraw only these rows, not the scrolling apartment catalog.
struct HousingCollectionStatusView: View {
    @ObservedObject var status: HousingCollectionStatus
    let busy: Bool
    var body: some View {
        if let progress = status.value {
            if busy {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView() }
            }
            Text(progress.text).font(.caption).monospacedDigit()
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let estimate = progress.estimateText(at: context.date)
                if !estimate.isEmpty { Text(estimate).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        if !status.backgroundMessage.isEmpty { Text(status.backgroundMessage).font(.caption).foregroundStyle(.secondary) }
        if let date = status.resumeAt {
            Text("다시 수집 가능한 시각: \(date.formatted(date: .numeric, time: .shortened))").font(.caption).foregroundStyle(.orange)
        }
    }
}
struct HousingExport: Codable { var version = 1; var regions: [HousingRegion]; var edits: [HousingEdit] }
struct HousingComplexView: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @EnvironmentObject private var store: HousingStore
    @EnvironmentObject private var sites: SiteTargetStore
    let complexID: String
    @State private var fields: [String: String] = [:]
    @State private var showMap = false
    @State private var reading = false
    @State private var detailTask: Task<Void, Never>?
    @State private var error: String?
    @State private var linkingKapt = false
    @State private var reviewingMerge = false
    private var complex: HousingComplex? { store.complexes.first { $0.id == complexID } }
    var body: some View {
        Form {
            if let complex {
                Section("단지 정보 · 사용자 수정") {
                    if complex.original != nil {
                        Button(reading ? "상세 수집 중…" : "이 단지의 최신 상세 수집") { loadDetail(complex) }.disabled(reading || store.isBusy)
                    }
                    ForEach(HousingField.allCases) { field in
                        if field.derived { LabeledContent(field.title,value:complex.fields[field.rawValue] ?? "미확인") }
                        else { VStack(alignment: .leading) { Text(field.title).font(.caption).foregroundStyle(.secondary)
                            NativeTextField(field.title, text: Binding(get: { fields[field.rawValue] ?? "" }, set: { fields[field.rawValue] = $0 }))
                        } }
                    }
                    Button("변경한 항목 저장") {
                        do { inputs.finishEditing(); let changed = fields.filter { complex.fields[$0.key, default: ""] != $0.value }; try store.edit(complex, fields: changed) } catch { self.error = error.localizedDescription }
                    }
                    Button("지도에서 좌표 지정·수정") { showMap = true }
                    if let c = complex.coordinate { Text("\(c.latitude, specifier: "%.8f"), \(c.longitude, specifier: "%.8f")").font(.caption) }
                    Button("평가대상지에 추가·갱신") {
                        do { guard let c = complex.coordinate else { throw PlannerFailure.message("지도에서 좌표를 먼저 지정하세요.") }; _ = try sites.saveManual(name: complex.name, address: complex.address, coordinate: c, housingID: complex.id) } catch { self.error = error.localizedDescription }
                    }
                }
                Section("단지 범위 가공") {
                    Button("주소 기반 통합 후보 직접 확인") { reviewingMerge = true }
                    Button("K-apt 연결·전체 단지 선택") { linkingKapt = true }
                    Text("주소가 같아도 자동으로 합치지 않습니다. 확인한 단지만 선택해 통합하며, 상세 재수집은 원본 코드로 갱신하므로 통합했던 단지가 별도 항목으로 다시 추가되지 않습니다.").font(.caption)
                    Button("분리할 새 단지 만들기 · 원본 연결 복사") {
                        do { _ = try store.add(name: complex.name + " (분리)", regionCode: complex.regionCode, fields: complex.fields, coordinate: complex.coordinate, sourceIDs: complex.sourceIDs) } catch { self.error = error.localizedDescription }
                    }
                    Text("분리한 단지는 목록에서 이름·주소·규모·좌표를 수정하세요. 같은 원본에 여러 단지를 연결할 수 있습니다.").font(.caption)
                    if complex.edited { Button("사용자 수정 지우고 원본으로 복원") { do { try store.reset(complex.id) } catch { self.error = error.localizedDescription } } }
                    Button("목록에서 숨기기", role: .destructive) { do { try store.hide(complex) } catch { self.error = error.localizedDescription } }
                }
                Section("원본 근거") {
                    Text(complex.sourceIDs.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    ForEach(complex.originals) { original in
                        DisclosureGroup((original.isKapt ? "K-apt · " : "공시가격 · ") + (original.fields["name"] ?? original.aptCode)) {
                            NavigationLink("이 원본의 소속 동·세부 값 보정") { HousingSourceEditView(source:original) }
                            ForEach(HousingField.allCases) { field in LabeledContent(field.title,value:original.fields[field.rawValue] ?? "") }
                            if let raw = original.fields["rawAreas"] { LabeledContent("원래 공시면적",value:raw) }
                            HousingAddressEvidenceView(source:original)
                            ForEach(Array(original.issues.enumerated()),id:\.offset) { _,issue in Text(issue).font(.caption).foregroundStyle(.orange) }
                            Text("산정자료 기준: \(original.fields["basisDate",default:"미수집"])").font(.caption)
                        }
                    }
                }
                if !complex.priorEdits.isEmpty {
                    Section("통합 전 사용자 수정 기록") {
                        ForEach(Array(complex.priorEdits.enumerated()),id:\.offset) { _,edit in
                            DisclosureGroup(edit.fields["name"] ?? edit.id) {
                                ForEach(HousingField.allCases.filter { edit.fields[$0.rawValue] != nil }) { field in LabeledContent(field.title,value:edit.fields[field.rawValue] ?? "") }
                                if let c = edit.coordinate { Text("좌표: \(c.latitude), \(c.longitude)").font(.caption) }
                                Text(edit.sourceIDs.joined(separator:"\n")).font(.caption2).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            } else { Text("숨겼거나 변경된 단지입니다. 목록으로 돌아가세요.") }
        }.navigationTitle(complex?.name ?? "단지 정보").navigationBarTitleDisplayMode(.inline)
            .onAppear { fields = complex?.fields ?? [:] }
            .onChange(of:complex?.fields) { old,new in if fields == old { fields = new ?? [:] } }
            .sheet(isPresented:$linkingKapt) { if let complex { HousingKaptLinkView(complex:complex) } }
            .sheet(isPresented:$reviewingMerge) { if let complex { HousingMergeReviewView(complex:complex) } }
            .sheet(isPresented: $showMap) {
                if let complex { CoordinateEditorView(title: "단지 좌표", coordinate: complex.coordinate, original: complex.original?.coordinate) { try store.edit(complex, fields: [:], coordinate: $0) } }
            }
            .onDisappear { detailTask?.cancel() }
    }
    private func loadDetail(_ complex: HousingComplex) {
        let sources = complex.originals.filter { !$0.isKapt }; guard !sources.isEmpty else { return }; reading = true; error = nil
        detailTask = Task {
            defer { reading = false; detailTask = nil }
            do {
                try await DeviceShareHooks.prepareRequest()
                for source in sources {
                try Task.checkCancellation()
                var updated = try await RealtyHousingClient().detail(source)
                if updated.fields["roadAddress", default: ""].isEmpty, KakaoRouteStore.shared.settings.mapFreeConfirmed, !KakaoRouteStore.shared.settings.key.isEmpty {
                    if let road = try await KakaoRouteStore.shared.roadAddress(for: updated) { updated.fields["roadAddress"] = road; updated.detailAt = Date(); updated.issues.removeAll { $0.contains("도로명주소") } }
                }
                var region = try store.originalRegion(source.regionCode)
                guard let index = region.records.firstIndex(where: { $0.id == source.id }) else { throw DeviceShareError.invalid }
                region.records[index] = updated; region.generation = max(Date().timeIntervalSince1970 * 1000,region.generation + 1)
                try store.importRegion(region)
                }
                if let value = self.complex { fields = value.fields }
            } catch is CancellationError { error = "수집을 중단했습니다." }
            catch { self.error = error.localizedDescription }
        }
    }
}
func housingCSV(_ complexes: [HousingComplex], regions: [HousingRegionSummary]) -> String {
    func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    let headings = ["고유ID", "원본ID", "법정동코드", "시도", "시군구", "법정동"] + HousingField.allCases.map(\.title) + ["위도", "경도"]
    let areas = Dictionary(regions.map { ($0.code, $0) }, uniquingKeysWith: { _, new in new })
    let rows = complexes.map { c -> String in
        let region = areas[c.regionCode]
        var values: [String] = [c.id, c.sourceIDs.joined(separator: ";"), c.regionCode]
        values.append(contentsOf: [region?.sido.name ?? "", region?.sigungu.name ?? "", region?.dong.name ?? ""])
        values.append(contentsOf: HousingField.allCases.map { c.fields[$0.rawValue] ?? "" })
        values.append(c.coordinate.map { String($0.latitude) } ?? "")
        values.append(c.coordinate.map { String($0.longitude) } ?? "")
        return values.map(quote).joined(separator: ",")
    }
    return "\u{FEFF}" + ([headings.map(quote).joined(separator: ",")] + rows).joined(separator: "\r\n")
}
