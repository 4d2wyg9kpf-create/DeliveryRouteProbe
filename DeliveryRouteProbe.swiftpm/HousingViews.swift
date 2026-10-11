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
    @State private var sido = "", district = "", dong = "", keyword = ""
    @State private var selected = Set<String>()
    @State private var merging = false
    @State private var mergeName = ""
    @State private var adding = false
    @State private var newName = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var document = DataTextDocument()
    @State private var job: Task<Void, Never>?
    @State private var error: String?
    private let client = RealtyHousingClient()
    private var regionCode: String { sido + district + dong }
    private var filtered: [HousingComplex] {
        store.complexes.filter { item in
            (dong.isEmpty || item.regionCode == regionCode) && (keyword.isEmpty || (item.name + item.address + (item.fields["jibunAddress"] ?? "")).localizedCaseInsensitiveContains(keyword))
        }
    }
    var body: some View {
        List {
            Section("공동주택 찾기") {
                NativeTextField("단지명 · 도로명주소 · 지번주소 검색", text: $keyword)
                Picker("시도", selection: $sido) { Text("선택").tag(""); ForEach(sidos) { Text($0.name).tag($0.code) } }.disabled(store.isBusy)
                Picker("시군구", selection: $district) { Text("선택").tag(""); ForEach(districts) { Text($0.name).tag($0.code) } }.disabled(store.isBusy)
                Picker("법정동 · 리", selection: $dong) { Text("전체 보관 자료").tag(""); ForEach(dongs) { Text($0.name).tag($0.code) } }.disabled(store.isBusy)
                Text("보관 지역 \(store.regions.count)곳 · 원본 \(store.regions.reduce(0) { $0 + $1.sourceCount })건 · 표시 \(filtered.count)건").font(.caption)
                Text("전국 수집 완료 여부는 보관 지역별로 확인하세요. 미수집 지역과 상세 미수집 항목은 빈칸으로 표시합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("원본 수집 · 공유") {
                Button("선택 법정동 목록 수집·새로고침") { collect(details: false) }.disabled(dong.isEmpty || store.isBusy)
                Button("선택 법정동 상세 수집 이어서") { collect(details: true) }.disabled(dong.isEmpty || store.isBusy)
                Button("전국 목록·상세 수집 이어서") { collectNational() }.disabled(store.isBusy)
                Text("모바일 지번검색 자료를 직접 요청합니다. 앱이 켜져 있는 동안 순차 수집하고, 완료된 법정동·단지는 저장해 이어서 수집합니다. iCloud에서 받은 자료는 재사용합니다.").font(.caption).foregroundStyle(.secondary)
                if store.isBusy { ProgressView(); Text(store.progress).font(.caption); Button("수집 중단") { job?.cancel() } }
                NavigationLink("기기 간 공유 폴더 설정") { DeviceSharingSettingsView() }
                Button("JSON 자료 가져오기") { importing = true }.disabled(store.isBusy)
                Button("보관 자료·사용자 수정 JSON 내보내기") {
                    do { document = DataTextDocument(String(decoding: try JSONEncoder().encode(HousingExport(regions: store.regions, edits: store.edits)), as: UTF8.self)); exporting = true } catch { self.error = error.localizedDescription }
                }
                Button("평가용 CSV 내보내기") { document = DataTextDocument(housingCSV(store.complexes, regions: store.regions)); exporting = true }
                if let error = error ?? store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if !store.regions.isEmpty {
                Section("수집 현황") {
                    ForEach(store.regions.filter { sido.isEmpty || $0.sido.code == sido }) { region in
                        Text("\(region.title) · 목록 \(region.sourceCount) / 상세 \(region.detailCount)").font(.caption)
                    }
                }
            }
            Section("단지 목록 · \(filtered.count)건") {
                Button("새 단지 추가") { adding = true }
                if selected.count > 1 { Button("선택한 \(selected.count)개를 하나로 합치기") { merging = true } }
                ForEach(Array(filtered.prefix(500))) { complex in
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
                if filtered.count > 500 { Text("500건까지 표시합니다. 법정동이나 검색어로 범위를 좁히세요.").font(.caption) }
            }
        }.navigationTitle("공동주택 목록").navigationBarTitleDisplayMode(.inline)
            .task { do { sidos = try await client.areas() } catch { self.error = error.localizedDescription; sidos = Array(Set(store.regions.map(\.sido))).sorted { $0.name < $1.name } } }
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
            } message: { Text("개별 원본과 기존 가공 기록은 남습니다. 합친 범위의 수치·주소는 직접 확인해 수정하세요.") }
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
            .onDisappear { job?.cancel() }
    }
    private func collect(details: Bool) {
        guard let s = sidos.first(where: { $0.code == sido }), let g = districts.first(where: { $0.code == district }), let d = dongs.first(where: { $0.code == dong }) else { return }
        start { try await collectRegion(s, g, d, details: details, refresh: !details) }
    }
    private func start(_ operation: @escaping () async throws -> Void) {
        store.isBusy = true; error = nil
        job = Task {
            defer { store.isBusy = false; job = nil }
            do { try await operation(); store.progress = "수집 자료를 저장했습니다." }
            catch is CancellationError { store.progress = "중단했습니다. 완료된 자료에서 이어서 수집할 수 있습니다." }
            catch { self.error = error.localizedDescription }
        }
    }
    private func collectRegion(_ s: HousingArea, _ g: HousingArea, _ d: HousingArea, details: Bool, refresh: Bool) async throws {
        let code = s.code + g.code + d.code
        var region: HousingRegion
        if !refresh, let existing = store.regions.first(where: { $0.code == code }) { region = existing }
        else { store.progress = "\(s.name) \(g.name) \(d.name) 목록 수집"; region = try await client.list(sido: s, sigungu: g, dong: d); try store.importRegion(region) }
        guard details else { return }
        defer { try? store.shareRegion(code) }
        for index in region.records.indices where region.records[index].detailAt == nil {
            try Task.checkCancellation(); store.progress = "\(region.title) · 상세 \(index+1)/\(region.records.count)"
            do {
                region.records[index] = try await client.detail(region.records[index])
                if region.records[index].fields["roadAddress", default: ""].isEmpty, KakaoRouteStore.shared.settings.mapFreeConfirmed, !KakaoRouteStore.shared.settings.key.isEmpty {
                    do { if let road = try await KakaoRouteStore.shared.roadAddress(for: region.records[index]) { region.records[index].fields["roadAddress"] = road; region.records[index].issues.removeAll { $0.contains("도로명주소") } } } catch is CancellationError { throw CancellationError() } catch { region.records[index].issues.append("주소 변환: " + error.localizedDescription) }
                }
            } catch is CancellationError { throw CancellationError() } catch { region.records[index].issues = [error.localizedDescription] }
            region.generation = Date().timeIntervalSince1970 * 1000; try store.importRegion(region, share: false)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
    private func collectNational() {
        start {
            for s in try await client.areas() {
                for g in try await client.areas(sido: s.code) {
                    for d in try await client.areas(sido: s.code, sigungu: g.code) {
                        try Task.checkCancellation()
                        do { try await collectRegion(s, g, d, details: true, refresh: false) }
                        catch is CancellationError { throw CancellationError() }
                        catch { store.errorMessage = "\(s.name) \(g.name) \(d.name): " + error.localizedDescription }
                    }
                }
            }
        }
    }
}
struct HousingExport: Codable { var version = 1; var regions: [HousingRegion]; var edits: [HousingEdit] }
struct HousingComplexView: View {
    @EnvironmentObject private var store: HousingStore
    @EnvironmentObject private var sites: SiteTargetStore
    let complexID: String
    @State private var fields: [String: String] = [:]
    @State private var showMap = false
    @State private var error: String?
    private var complex: HousingComplex? { store.complexes.first { $0.id == complexID } }
    var body: some View {
        Form {
            if let complex {
                Section("단지 정보 · 사용자 수정") {
                    ForEach(HousingField.allCases) { field in
                        VStack(alignment: .leading) { Text(field.title).font(.caption).foregroundStyle(.secondary)
                            NativeTextField(field.title, text: Binding(get: { fields[field.rawValue] ?? "" }, set: { fields[field.rawValue] = $0 }))
                        }
                    }
                    Button("변경한 항목 저장") {
                        do { let changed = fields.filter { complex.fields[$0.key, default: ""] != $0.value }; try store.edit(complex, fields: changed) } catch { self.error = error.localizedDescription }
                    }
                    Button("지도에서 좌표 지정·수정") { showMap = true }
                    if let c = complex.coordinate { Text("\(c.latitude, specifier: "%.8f"), \(c.longitude, specifier: "%.8f")").font(.caption) }
                    Button("평가대상지에 추가·갱신") {
                        do { guard let c = complex.coordinate else { throw PlannerFailure.message("지도에서 좌표를 먼저 지정하세요.") }; _ = try sites.saveManual(name: complex.name, address: complex.address, coordinate: c, housingID: complex.id) } catch { self.error = error.localizedDescription }
                    }
                }
                Section("단지 범위 가공") {
                    Button("분리할 새 단지 만들기 · 원본 연결 복사") {
                        do { _ = try store.add(name: complex.name + " (분리)", regionCode: complex.regionCode, fields: complex.fields, coordinate: complex.coordinate, sourceIDs: complex.sourceIDs) } catch { self.error = error.localizedDescription }
                    }
                    Text("분리한 단지는 목록에서 이름·주소·규모·좌표를 수정하세요. 같은 원본에 여러 단지를 연결할 수 있습니다.").font(.caption)
                    if complex.edited { Button("사용자 수정 지우고 원본으로 복원") { do { try store.reset(complex.id) } catch { self.error = error.localizedDescription } } }
                    Button("목록에서 숨기기", role: .destructive) { do { try store.hide(complex) } catch { self.error = error.localizedDescription } }
                }
                Section("원본 근거") {
                    Text(complex.sourceIDs.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    if let original = complex.original {
                        ForEach(HousingField.allCases) { field in LabeledContent(field.title, value: original.fields[field.rawValue] ?? "") }
                        ForEach(Array(original.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption).foregroundStyle(.orange) }
                        Text("산정자료 기준: \(original.fields["basisDate", default: "미수집"])").font(.caption)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            } else { Text("숨겼거나 변경된 단지입니다. 목록으로 돌아가세요.") }
        }.navigationTitle(complex?.name ?? "단지 정보").navigationBarTitleDisplayMode(.inline)
            .onAppear { fields = complex?.fields ?? [:] }
            .sheet(isPresented: $showMap) {
                if let complex { CoordinateEditorView(title: "단지 좌표", coordinate: complex.coordinate, original: complex.original?.coordinate) { try store.edit(complex, fields: [:], coordinate: $0) } }
            }
    }
}
func housingCSV(_ complexes: [HousingComplex], regions: [HousingRegion]) -> String {
    func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    let headings = ["고유ID", "원본ID", "법정동코드", "시도", "시군구", "법정동"] + HousingField.allCases.map(\.title) + ["위도", "경도"]
    let areas = Dictionary(regions.map { ($0.code, $0) }, uniquingKeysWith: { _, new in new })
    let rows = complexes.map { c -> String in
        let region = areas[c.regionCode]
        let values = [c.id, c.sourceIDs.joined(separator: ";"), c.regionCode, region?.sido.name ?? "", region?.sigungu.name ?? "", region?.dong.name ?? ""] + HousingField.allCases.map { c.fields[$0.rawValue] ?? "" } + [c.coordinate.map { String($0.latitude) } ?? "", c.coordinate.map { String($0.longitude) } ?? ""]
        return values.map(quote).joined(separator: ",")
    }
    return "\u{FEFF}" + ([headings.map(quote).joined(separator: ",")] + rows).joined(separator: "\r\n")
}
