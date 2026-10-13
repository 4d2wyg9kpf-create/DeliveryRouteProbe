import SwiftUI

struct BuildingRegisterView: View {
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var housing: HousingStore
    @EnvironmentObject private var references: BuildingReferenceStore
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject private var api = PublicDataStore.shared
    @State private var roadAddress: String
    @State private var dong = ""
    @State private var addressKey = ""
    @State private var buildings: [EvaluationBuilding] = []
    @State private var selected: EvaluationBuilding?
    @State private var choice = BuildingChoice.single
    @State private var defaultBuildingID: String?
    @State private var facts: [String:BuildingFact] = [:]
    @State private var point: TMapCoordinate?
    @State private var entranceSource = "사용자 확인 · 건물 출입구"
    @State private var entranceConfirmed = false
    @State private var editingPoint = false
    @State private var showingSettings = false
    @State private var loading = false
    @State private var query: Task<Void,Never>?
    @State private var message: String?
    init(roadAddress: String = "") { _roadAddress = State(initialValue:roadAddress) }
    var body: some View {
        Form {
            Section("평가할 개별 건물") {
                NativeTextField("도로명주소 · 건물번호까지",text:$roadAddress).frame(minHeight:44).disabled(loading)
                NativeTextField("동 번호·동 명칭 (생략 가능)",text:$dong).frame(minHeight:44).disabled(loading)
                Text("동을 생략하면 단독 건물 또는 가장 앞선 동을 선택합니다. 층·호를 별도 건물로 평가하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                Button(loading ? "건축물대장 조회 중…" : "건축물대장으로 건물 확인") { load() }.disabled(loading || api.isBusy)
                if loading { ProgressView(); Button("조회 중단") { query?.cancel() } }
            }
            if let building = selected {
                Section("선택한 건물") {
                    Text([building.name,building.dongName].filter { !$0.isEmpty }.joined(separator:" ")).bold()
                    Text(building.roadAddress).font(.caption)
                    Text(choice == .specifiedDong ? "지정한 동" : choice == .firstDong ? "상세주소 중 가장 앞선 동" : "해당 주소의 단독 건물").font(.caption)
                    Text("같은 주소의 건물 \(buildings.count)개 · 건축물대장으로 동을 구분합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("건물 입구") {
                    Button("이 건물의 출입구 좌표 확인·수정") { editingPoint = true }
                    if let point { Text("\(point.latitude,specifier:"%.8f"), \(point.longitude,specifier:"%.8f")").font(.caption) }
                    NativeTextField("출입구 좌표 출처",text:$entranceSource).frame(minHeight:44)
                    Toggle("선택한 건물의 출입구임을 확인",isOn:$entranceConfirmed)
                    Text("단지 대표좌표·단지 정문·건물 중심점을 동의 현관으로 자동 사용하지 않습니다. 승인받은 출입구 자료, 지도 또는 네이버 공유 지점으로 해당 입구를 확인하세요.").font(.caption).foregroundStyle(.secondary)
                    Button("개별 건물 평가대상에 저장·갱신") { save() }.buttonStyle(.borderedProminent).disabled(point == nil || !entranceConfirmed || loading)
                }
                Section("건물 정보 · 항목별 출처") {
                    ForEach(facts.keys.sorted(),id:\.self) { key in
                        if let fact = facts[key] {
                            VStack(alignment:.leading,spacing:3) {
                                Text(HousingField(rawValue:key)?.title ?? buildingFactTitle(key)).font(.caption).foregroundStyle(.secondary)
                                Text(fact.value)
                                Text("\(fact.source == .registry ? "건축물대장" : fact.source == .realty ? "공시가격" : "K-apt") · \(fact.scope == .building ? "개별 건물" : "단지 정보로 보충")").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("대장에 값이 있는 항목은 유지하며, 아파트의 빈 항목만 공시가격 → K-apt 순으로 보충합니다. 단지 전체 수치는 개별 동 수치와 구분합니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message { Section { Text(message).font(.caption).textSelection(.enabled) } }
            Section("조회 설정") {
                Button("공공데이터 키·건축물대장 활용승인") { showingSettings = true }
                NativeTextField(housing.hasAddressKey ? "주소 검색 승인키 변경 시 입력" : "주소 검색 API 승인키",text:$addressKey,keyboard:.asciiCapable,secure:true).frame(minHeight:44)
                Button("주소 검색 승인키 저장") {
                    do { inputs.finishEditing(); try housing.saveAddressKey(addressKey); addressKey = ""; message = "주소 검색 승인키를 저장했습니다." }
                    catch { message = error.localizedDescription }
                }.disabled(loading || addressKey.isEmpty)
                NavigationLink("K-apt 표준지 목록 수집·확인") { KaptBuildingReferenceView() }
            }
        }.navigationTitle("개별 건물 확인").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showingSettings) { PublicDataSettingsView(store:api) }
            .sheet(isPresented:$editingPoint) {
                CoordinateEditorView(title:"선택한 건물의 출입구",coordinate:point) { value in
                    point = value; entranceConfirmed = false
                }
            }
            .onDisappear { query?.cancel() }
    }
    private func load() {
        inputs.finishEditing(); loading = true; message = nil; selected = nil; defaultBuildingID = nil; point = nil; entranceConfirmed = false
        let requestedRoad = roadAddress, requestedDong = dong
        query = Task {
            defer { loading = false; query = nil }
            do {
                let addresses = try await housing.buildingAddresses(requestedRoad)
                var all: [String:EvaluationBuilding] = [:], parcels = Set<String>()
                for address in addresses {
                    let parameters = try BuildingLedgerClient.parameters(address,page:1)
                    let parcel = ["sigunguCd","bjdongCd","platGbCd","bun","ji"].map { parameters[$0]! }.joined(separator:"|")
                    guard parcels.insert(parcel).inserted else { continue }
                    for building in try await BuildingLedgerClient.lookup(address,api:api) { all[building.id] = building }
                }
                let values = all.values.sorted { BuildingAddress.dongLess($0.dongName,$1.dongName) }
                let expected = addresses.flatMap(\.dongNames)
                let (building,reason) = try BuildingSelector.choose(values,roadAddress:requestedRoad,dong:requestedDong,expectedDongNames:expected)
                defaultBuildingID = try? BuildingSelector.choose(values,roadAddress:requestedRoad,expectedDongNames:expected).0.id
                let region = addresses.first?.administrativeCode
                let sources = try housing.buildingSupplements(roadAddress:building.roadAddress,regionCode:region)
                var realty = BuildingFacts.consensus(sources.filter { !$0.isKapt }.map(\.fields))
                var kapt = BuildingFacts.consensus(sources.filter(\.isKapt).map(\.fields) + [references.supplementalFields(building.roadAddress)])
                let apartment = building.fields["use",default:""].contains("아파트") || !kapt.isEmpty
                var issues: [String] = []
                if apartment, let region {
                    do { realty = try await housing.refreshBuildingRealty(roadAddress:building.roadAddress,regionCode:region) }
                    catch is CancellationError { throw CancellationError() }
                    catch { issues.append("공시가격 보충: " + error.localizedDescription) }
                    do { let fetched = try await BuildingSupplementClient.kapt(roadAddress:building.roadAddress,region:region,api:api); kapt = BuildingFacts.consensus([kapt,fetched]) }
                    catch is CancellationError { throw CancellationError() }
                    catch { issues.append("K-apt 보충: " + error.localizedDescription) }
                }
                facts = BuildingFacts.resolve(registry:building.fields,realty:realty,kapt:kapt,apartment:apartment)
                buildings = values; selected = building; choice = reason
                if let previous = sites.records.first(where:{ $0.building?.identity == building.roadKey + "|" + building.id }) {
                    point = previous.effectiveCoordinate; entranceSource = previous.building?.entranceSource ?? entranceSource; entranceConfirmed = true
                }
                message = (["건물을 확인했습니다. 해당 건물의 출입구를 확인하고 저장하세요."] + issues).joined(separator:"\n")
            } catch is CancellationError { message = "조회를 중단했습니다." }
            catch { message = error.localizedDescription }
        }
    }
    private func save() {
        do {
            inputs.finishEditing()
            guard let building = selected, let point, entranceConfirmed else { throw DeviceShareError.invalid }
            let selection = BuildingSelection(building:building,choice:choice,entranceSource:BuildingAddress.clean(entranceSource),
                entranceID:"confirmed:" + UUID().uuidString,longitude:point.longitude,latitude:point.latitude,defaultForAddress:defaultBuildingID == building.id)
            _ = try sites.saveBuilding(selection,facts:facts)
            message = "선택한 개별 건물과 출입구를 저장했습니다."
        } catch { message = error.localizedDescription }
    }
}

struct KaptBuildingReferenceView: View {
    @EnvironmentObject private var references: BuildingReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var evaluation: EvaluationReferenceStore
    @ObservedObject private var api = PublicDataStore.shared
    @State private var keyword = ""
    @State private var showingSettings = false
    @State private var message: String?
    @State private var limit = 100
    private var filtered: [KaptReferenceAddress] {
        references.catalog.addresses.filter { keyword.isEmpty || ($0.roadAddress + " " + $0.names.joined(separator:" ")).localizedCaseInsensitiveContains(keyword) }
    }
    var body: some View {
        List {
            Section("K-apt 전체 도로명주소 → 표준지 목록") {
                Button("공공데이터 키·K-apt 활용승인") { showingSettings = true }
                Button("전국 K-apt 목록·주소 수집 이어서") { references.start(api:api) }.disabled(references.isBusy || api.isBusy)
                if references.isBusy { ProgressView(); Button("수집 중단") { references.stop() } }
                Text(references.progress).font(.caption)
                BuildingReferenceBackgroundStatus(status:references.collectionStatus)
                Text("원본 \(references.archive.records.count)단지 · 표준 주소 \(references.catalog.addresses.count)개").font(.caption)
                Text("주소 공란 제외 \(references.catalog.missingAddressIDs.count)단지 · 중복 주소 \(references.catalog.duplicateAddressCount)건 · 주소 미확인 \(references.catalog.unresolvedIDs.count)단지").font(.caption).foregroundStyle(.secondary)
                Text("도로명주소가 여러 개면 각 주소를 포함하고, 다른 등록과 같은 주소는 한 번만 포함합니다. 상세 미수집을 공란으로 제외하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                Button("확인한 전체 주소를 표준 건물 목록에 적용") {
                    do {
                        let standards = try references.standardSites(sites.records).map(EvaluationSite.init)
                        try evaluation.setStandardPopulation(standards,token:references.populationToken)
                        message = "전체 \(standards.count)개 표준 건물을 적용했습니다. 원자료를 확인한 뒤 새 기준을 확정하세요."
                    } catch { message = error.localizedDescription }
                }.disabled(references.isBusy)
                Text("모든 표준 주소의 기본 건물·입구가 확인되어야 전체 표준 목록을 적용합니다. 일부 확인된 주소로 조용히 기준분포를 만들지 않습니다.").font(.caption).foregroundStyle(.secondary)
                if let error = message ?? references.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("표준 주소 확인") {
                NativeTextField("도로명주소·단지명 검색",text:$keyword).frame(minHeight:44)
                ForEach(Array(filtered.prefix(limit))) { address in
                    NavigationLink { BuildingRegisterView(roadAddress:address.roadAddress) } label: {
                        VStack(alignment:.leading,spacing:3) {
                            Text(address.roadAddress)
                            Text(address.names.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                            let verified = sites.records.contains { $0.building?.building.roadKey == address.id && $0.building?.isDefaultForAddress == true }
                            Text(verified ? "기본 건물·입구 확인됨" : "기본 건물·입구 확인 필요").font(.caption2).foregroundStyle(verified ? Color.secondary : Color.orange)
                        }
                    }
                }
                if filtered.count > limit { Button("주소 더 보기") { limit += 100 } }
            }
        }.navigationTitle("K-apt 표준지 목록").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showingSettings) { PublicDataSettingsView(store:api) }
    }
}

private struct BuildingReferenceBackgroundStatus: View {
    @ObservedObject var status: HousingCollectionStatus
    var body: some View {
        if !status.backgroundMessage.isEmpty { Text(status.backgroundMessage).font(.caption).foregroundStyle(.secondary) }
        if let value = status.value {
            if let fraction = value.fraction { ProgressView(value:fraction) }
            Text(value.summary).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func buildingFactTitle(_ key: String) -> String {
    ["families":"가구수", "basementFloors":"지하층수", "height":"건물 높이(m)", "buildingArea":"건축면적(m²)", "totalArea":"연면적(m²)", "landArea":"대지면적(m²)", "structure":"구조", "buildingCoverage":"건폐율(%)", "floorAreaRatio":"용적률(%)", "earthquakeDesign":"내진설계 적용 여부"][key] ?? key
}
