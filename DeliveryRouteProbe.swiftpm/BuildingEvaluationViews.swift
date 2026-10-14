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
    @State private var review: BuildingComplexReview?
    @State private var showingReview = false
    @State private var confirmedDefault = false
    @State private var expectedDongs: [String] = []
    init(roadAddress: String = "", dong: String = "") { _roadAddress = State(initialValue:roadAddress); _dong = State(initialValue:dong) }
    private var sharedComplex: ManagedBuildingComplex? {
        guard let selected, let binding = review?.binding(selected) else { return nil }
        return references.managedComplexes[binding.complexID]
    }
    private var canConfirmDefault: Bool {
        guard defaultBuildingID == nil, let selected, !BuildingAddress.dongKey(selected.dongName).isEmpty else { return false }
        let available = Set(buildings.map { BuildingAddress.dongKey($0.dongName) })
        guard Set(expectedDongs.map(BuildingAddress.dongKey)).isSubset(of:available), buildings.allSatisfy({ !BuildingAddress.dongKey($0.dongName).isEmpty }) else { return false }
        return !buildings.contains { BuildingAddress.dongLess($0.dongName,selected.dongName) && BuildingAddress.dongKey($0.dongName) != BuildingAddress.dongKey(selected.dongName) }
    }
    var body: some View {
        Form {
            Section("평가할 개별 건물") {
                NativeTextField("도로명주소 · 건물번호까지",text:$roadAddress).frame(minHeight:44).disabled(loading)
                NativeTextField("동 번호·동 명칭 (생략 가능)",text:$dong).frame(minHeight:44).disabled(loading)
                Text("동을 생략하면 단독 건물 또는 가장 앞선 동을 선택합니다. 층·호를 별도 건물로 평가하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                Button(loading ? "건축물대장 조회 중…" : "건축물대장으로 건물 확인") { load() }.disabled(loading || api.isBusy)
                if loading { ProgressView(); Button("조회 중단") { query?.cancel() } }
            }
            if !buildings.isEmpty {
                Section("같은 주소의 건물 선택") {
                    Picker("평가할 건물",selection:Binding(get:{ selected?.id ?? "" },set:{ chooseBuilding($0) })) {
                        Text("건물을 선택하세요").tag("")
                        ForEach(buildings) { building in Text("\(building.name) \(building.dongName) · \(building.id)").tag(building.id) }
                    }
                    if let review {
                        Button("K-apt 등록 비교·중복 판별·건물 소속 확인") { showingReview = true }.disabled(loading)
                        Text(review.usable ? "등록 판별 저장됨 · 소속 미확인 건물은 공용 정보 보류" : "단지 판별 미확인 · 공용 정보 보류").font(.caption).foregroundStyle(review.usable ? Color.secondary : Color.orange)
                    }
                }
            }
            if let building = selected {
                Section("선택한 건물") {
                    Text([building.name,building.dongName].filter { !$0.isEmpty }.joined(separator:" ")).bold()
                    Text(building.roadAddress).font(.caption)
                    Text(choice == .specifiedDong ? "지정한 동" : choice == .firstDong ? "상세주소 중 가장 앞선 동" : "해당 주소의 단독 건물").font(.caption)
                    Text("같은 주소의 건물 \(buildings.count)개 · 건축물대장으로 동을 구분합니다.").font(.caption).foregroundStyle(.secondary)
                    Text("소속 총괄표제부: \(building.parentRegistryID ?? "미확인")").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    if canConfirmDefault { Toggle("동 번호가 겹친 첫 동 중 이 건물을 주소의 기본값으로 확인",isOn:$confirmedDefault) }
                }
                Section("이 건물이 사용하는 단지 공용 정보") {
                    if let complex = sharedComplex {
                        Text(complex.name).bold()
                        Text("현황 원본 \(complex.adoptedKaptID) · 같은 단지 건물끼리 공유").font(.caption).foregroundStyle(.secondary)
                        ForEach(complex.sharedFacts.keys.sorted(),id:\.self) { key in
                            if let fact = complex.sharedFacts[key] {
                                VStack(alignment:.leading,spacing:3) {
                                    Text(buildingFactTitle(key)).font(.caption).foregroundStyle(.secondary); Text(fact.value)
                                    Text(fact.source == .registry ? "소속 총괄표제부" : fact.source == .realty ? "소속 확인된 공시가격 원본" : "채택한 K-apt 등록").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else { Text("관리단지 소속을 확인한 뒤 주차대수 등 공용 정보를 적용합니다.").font(.caption).foregroundStyle(.orange) }
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
                                Text(key == "parking" && fact.scope == .building ? "이 건물의 대장상 주차대수" : HousingField(rawValue:key)?.title ?? buildingFactTitle(key)).font(.caption).foregroundStyle(.secondary)
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
            .sheet(isPresented:$showingReview) {
                if let review { BuildingComplexReviewView(review:review) { saved in
                    self.review = saved; if let selected { facts = saved.individualFacts(selected) }
                    message = "단지 판별과 건물 소속을 저장했습니다. 같은 관리단지의 기존 건물 정보도 갱신했습니다."
                } }
            }
            .onDisappear { query?.cancel() }
    }
    private func chooseBuilding(_ id: String) {
        guard let building = buildings.first(where:{ $0.id == id }) else { selected = nil; return }
        selected = building; choice = .specifiedDong; point = nil; entranceConfirmed = false; confirmedDefault = false
        facts = review?.individualFacts(building) ?? BuildingFacts.resolve(registry:building.fields,realty:[:],kapt:[:],apartment:false)
        if let previous = sites.records.first(where:{ $0.building?.identity == building.roadKey + "|" + building.id }) {
            point = previous.effectiveCoordinate; entranceSource = previous.building?.entranceSource ?? entranceSource; entranceConfirmed = true
            if previous.building?.isDefaultForAddress == true && defaultBuildingID == nil { confirmedDefault = true }
        }
    }
    private func load() {
        inputs.finishEditing(); loading = true; message = nil; selected = nil; review = nil; buildings = []
        defaultBuildingID = nil; confirmedDefault = false; point = nil; entranceConfirmed = false
        let requestedRoad = roadAddress, requestedDong = dong
        query = Task {
            defer { loading = false; query = nil }
            do {
                let addresses = try await housing.buildingAddresses(requestedRoad)
                var all: [String:EvaluationBuilding] = [:], groups: [String:RegistryBuildingComplex] = [:], parcels = Set<String>(), issues: [String] = []
                for address in addresses {
                    let parameters = try BuildingLedgerClient.parameters(address,page:1)
                    let parcel = ["sigunguCd","bjdongCd","platGbCd","bun","ji"].map { parameters[$0]! }.joined(separator:"|")
                    guard parcels.insert(parcel).inserted else { continue }
                    var titles = try await BuildingLedgerClient.lookup(address,api:api)
                    do {
                        let context = try await BuildingLedgerClient.context(address,buildings:titles,api:api)
                        titles = context.buildings
                        for group in context.groups {
                            if let prior = groups[group.id], prior != group { throw BuildingEvaluationError.message("같은 총괄표제부의 응답이 달라 다시 조회해야 합니다.") }
                            groups[group.id] = group
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { issues.append("상위 대장 소속 미확인: " + error.localizedDescription) }
                    for building in titles {
                        if let prior = all[building.id], prior != building { throw BuildingEvaluationError.message("같은 건물 대장의 응답이 달라 다시 조회해야 합니다.") }
                        all[building.id] = building
                    }
                }
                let values = all.values.sorted { BuildingAddress.dongLess($0.dongName,$1.dongName) }
                buildings = values; expectedDongs = addresses.flatMap(\.dongNames)
                defaultBuildingID = try? BuildingSelector.choose(values,roadAddress:requestedRoad,expectedDongNames:expectedDongs).0.id
                let regions = Array(Set(addresses.compactMap(\.administrativeCode))).sorted()
                var price: [String:BuildingComplexSource] = [:]
                for region in regions {
                    for source in try housing.buildingSupplements(roadAddress:requestedRoad,regionCode:region).filter({ !$0.isKapt }) {
                        price[source.id] = BuildingSupplementClient.source(source)
                    }
                    do {
                        for source in try await housing.refreshBuildingRealty(roadAddress:requestedRoad,regionCode:region) { price[source.id] = BuildingSupplementClient.source(source) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { issues.append("공시가격 보충: " + error.localizedDescription) }
                }
                do {
                    var candidates = try await BuildingSupplementClient.kapt(roadAddress:requestedRoad,regions:regions,
                        knownCodes:references.connectedKaptCodes(requestedRoad),jibunAddresses:addresses.map(\.jibunAddress),api:api)
                    var comparedRegions = Set(regions), comparedRoads = Set([BuildingAddress.key(requestedRoad) ?? ""])
                    var pendingRoads = candidates.flatMap(\.roadAddresses), cursor = 0, comparisonComplete = true
                    var comparedParcels = addresses.map(\.jibunAddress)
                    while cursor < pendingRoads.count && comparedRoads.count <= 100 {
                        let otherRoad = pendingRoads[cursor]; cursor += 1
                        guard let key = BuildingAddress.key(otherRoad), comparedRoads.insert(key).inserted else { continue }
                        do {
                            let related = try await housing.buildingAddresses(otherRoad)
                            comparedParcels.append(contentsOf:related.map(\.jibunAddress))
                            let newRegions = Set(related.compactMap(\.administrativeCode)).subtracting(comparedRegions)
                            if !newRegions.isEmpty {
                                candidates = try await BuildingSupplementClient.kapt(roadAddress:requestedRoad,regions:newRegions.sorted(),
                                    knownCodes:references.connectedKaptCodes(otherRoad),jibunAddresses:comparedParcels,cached:candidates,api:api)
                                comparedRegions.formUnion(newRegions); pendingRoads.append(contentsOf:candidates.flatMap(\.roadAddresses))
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch { comparisonComplete = false; issues.append("연결 주소의 단지 비교 미완료: " + otherRoad + " · " + error.localizedDescription) }
                    }
                    if cursor < pendingRoads.count { comparisonComplete = false; issues.append("연결 주소가 많아 비교를 보류했습니다.") }
                    if !candidates.isEmpty {
                        var draft = try BuildingComplexReview.draft(roadAddress:requestedRoad,buildings:values,groups:groups.values.sorted { $0.id < $1.id },
                            candidates:candidates,realty:price.values.sorted { $0.id < $1.id },previous:references.complexReview(requestedRoad))
                        draft.comparisonComplete = comparisonComplete
                        if !comparisonComplete { draft.confirmed = false; draft.automatic = false }
                        draft = draft.reusingManagementDecision(references.complexReviews)
                        try references.saveComplexReview(draft); try sites.applyComplexReviews(references.complexReviews)
                        review = references.complexReview(requestedRoad)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append("K-apt 단지 판별: " + error.localizedDescription) }
                do {
                    let (building,reason) = try BuildingSelector.choose(values,roadAddress:requestedRoad,dong:requestedDong,expectedDongNames:expectedDongs)
                    chooseBuilding(building.id); choice = reason
                } catch { issues.append(error.localizedDescription) }
                message = (["개별 건물의 출입구와 관리단지 소속을 확인하세요."] + issues).joined(separator:"\n")
            } catch is CancellationError { message = "조회를 중단했습니다." }
            catch { message = error.localizedDescription }
        }
    }
    private func save() {
        do {
            inputs.finishEditing()
            guard let building = selected, let point, entranceConfirmed else { throw DeviceShareError.invalid }
            let selection = BuildingSelection(building:building,choice:choice,entranceSource:BuildingAddress.clean(entranceSource),
                entranceID:"confirmed:" + UUID().uuidString,longitude:point.longitude,latitude:point.latitude,defaultForAddress:defaultBuildingID == building.id || (canConfirmDefault && confirmedDefault))
            _ = try sites.saveBuilding(selection,facts:facts)
            try sites.applyComplexReviews(references.complexReviews)
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
        references.standardAddresses.filter { keyword.isEmpty || ($0.roadAddress + " " + $0.names.joined(separator:" ")).localizedCaseInsensitiveContains(keyword) }
    }
    var body: some View {
        List {
            Section("K-apt 전체 도로명주소 → 표준지 목록") {
                Button("공공데이터 키·K-apt 활용승인") { showingSettings = true }
                Button("전국 K-apt 목록·주소 수집 이어서") { references.start(api:api) }.disabled(references.isBusy || api.isBusy)
                if references.isBusy { ProgressView(); Button("수집 중단") { references.stop() } }
                Text(references.progress).font(.caption)
                BuildingReferenceBackgroundStatus(status:references.collectionStatus)
                Text("원본 \(references.archive.records.count)단지 · 표준 주소 \(references.standardAddresses.count)개").font(.caption)
                Text("주소 공란 제외 \(references.catalog.missingAddressIDs.count)단지 · 중복 주소 \(references.catalog.duplicateAddressCount)건 · 주소 미확인 \(references.catalog.unresolvedIDs.count)단지").font(.caption).foregroundStyle(.secondary)
                Text("여러 도로명주소는 각각 포함하며, 같은 주소는 목록에서 한 번만 표시합니다. 중복·별개·과거 등록은 건축물대장과 비교해 판별하고 원본을 보존합니다.").font(.caption).foregroundStyle(.secondary)
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
    ["families":"가구수", "complexHouseholds":"관리단지 전체 세대수", "complexBuildings":"관리단지 전체 동수", "parking":"단지 전체 공용 주차대수", "parkingPerHousehold":"관리단지 세대당 주차대수", "parkingGround":"지상 주차대수", "parkingUnderground":"지하 주차대수", "managementOffice":"관리사무소 연락처", "basementFloors":"지하층수", "height":"건물 높이(m)", "buildingArea":"건축면적(m²)", "totalArea":"연면적(m²)", "landArea":"대지면적(m²)", "structure":"구조", "buildingCoverage":"건폐율(%)", "floorAreaRatio":"용적률(%)", "earthquakeDesign":"내진설계 적용 여부"][key] ?? key
}
