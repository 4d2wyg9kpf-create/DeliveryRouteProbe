import SwiftUI

struct KaptPrimaryCatalogView: View {
    @EnvironmentObject private var references: BuildingReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var evaluation: EvaluationReferenceStore
    @ObservedObject private var api = PublicDataStore.shared
    @State private var keyword = ""
    @State private var mode = "included"
    @State private var province = ""
    @State private var district = ""
    @State private var limit = 100
    @State private var settings = false
    @State private var message: String?
    private var provinces: [String] { Set(references.archive.records.flatMap(\.roads).compactMap { BuildingAddress.key($0)?.split(separator:" ").first.map(String.init) }).sorted() }
    private func districtOf(_ road: String) -> String {
        let words = (BuildingAddress.key(road) ?? "").split(separator:" ")
        return words.dropFirst().dropLast(2).joined(separator:" ")
    }
    private var districts: [String] {
        Set(references.archive.records.flatMap(\.roads).filter { province.isEmpty || (BuildingAddress.key($0) ?? "").hasPrefix(province + " ") }.map(districtOf).filter { !$0.isEmpty }).sorted()
    }
    private var scoped: [KaptReferenceRecord] {
        references.archive.records.filter { record in
            (province.isEmpty || record.roads.contains { (BuildingAddress.key($0) ?? "").hasPrefix(province + " ") && (district.isEmpty || districtOf($0) == district) }) &&
            (keyword.isEmpty || ([record.id,record.name] + record.roads + [record.fields["jibunAddress",default:""]]).joined(separator:" ").localizedCaseInsensitiveContains(keyword))
        }
    }
    private var rows: [KaptReferenceRecord] {
        scoped.filter { record in
            switch mode {
            case "excluded": return references.isExcluded(record)
            case "pending": return !references.isExcluded(record) && references.currentDecision(record) == nil
            case "valid": return references.currentDecision(record)?.disposition == .accepted
            default: return !references.isExcluded(record)
            }
        }
    }
    var body: some View {
        List {
            collectionSection
            Section("K-apt 단지 목록") {
                NativeTextField("단지명·주소·K-apt 코드",text:$keyword).frame(minHeight:44)
                Picker("시도",selection:$province) { Text("전국").tag(""); ForEach(provinces,id:\.self) { Text($0).tag($0) } }
                Picker("시군구",selection:$district) { Text("전체").tag(""); ForEach(districts,id:\.self) { Text($0).tag($0) } }
                Picker("표시",selection:$mode) {
                    Text("목록").tag("included"); Text("검증 필요").tag("pending"); Text("유효").tag("valid"); Text("제외 기록").tag("excluded")
                }
                ForEach(Array(rows.prefix(limit))) { record in
                    NavigationLink { KaptLinkReviewView(kaptID:record.id) } label: { KaptPrimaryRow(record:record) }
                }
                if rows.count > limit { Button("단지 더 보기 · \(rows.count-limit)개 남음") { limit += 100 } }
            }
            Section("자료 보관") {
                NavigationLink("기존 공시가격 수집 자료 확인·내보내기") { HousingCatalogView() }
                NavigationLink("기기 간 공유 폴더 설정") { DeviceSharingSettingsView() }
                Text("기존 법정동별 원본과 과거 판별 기록은 보존합니다. 새 연결은 직접 승인하며, 제외 기록도 확인·복원할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("K-apt 단지 연결").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$settings) { PublicDataSettingsView(store:api) }
            .onChange(of:province) { _,_ in district = ""; limit = 100 }
            .onChange(of:keyword) { _,_ in limit = 100 }
            .onChange(of:mode) { _,_ in limit = 100 }
            .onChange(of:references.archive.concordance?.reviews.count) { _,_ in applyProfiles() }
            .onChange(of:references.isBusy) { _,busy in if !busy { applyProfiles() } }
    }
    private var collectionSection: some View {
        Section("K-apt → 공시가격 → 직접 검증") {
            Button("공공데이터 키·K-apt 활용승인") { settings = true }
            NavigationLink("주소 API 승인키·개별 건물 확인") { BuildingRegisterView() }
            Button("전국 K-apt 단지·주소 대조 수집 이어서") { references.start(api:api) }.disabled(references.isBusy || api.isBusy)
            if !province.isEmpty || !keyword.isEmpty {
                Button("현재 지역·검색의 \(scoped.count)개 단지 수집 이어서") { references.start(api:api,codes:Set(scoped.map(\.id))) }.disabled(references.isBusy || api.isBusy || scoped.isEmpty)
            }
            KaptPrimaryCollectionStatus(status:references.collectionStatus)
            if references.isBusy { Button("수집 중단") { references.stop() } }
            Text(references.progress).font(.caption)
            Text("원본 \(references.archive.records.count)개 · 유효 \(references.validKaptRecords.count)개 · 검증 필요 \(references.pendingKaptRecords.count)개").font(.caption)
            Text("도로명주소 공란 \(references.catalog.missingAddressIDs.count)개는 수집 대상에서 제외합니다. 도로명검색에 결과가 없으면 주소 API로 지번을 확인해 재검색합니다.").font(.caption).foregroundStyle(.secondary)
            Text("기본 연결은 1:1 제안입니다. 한 단지를 여러 공시가격 단지에 연결하거나 여러 K-apt 단지를 같은 공시가격 단지에 연결할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            Button("유효 단지마다 표준 건물 하나씩 적용") {
                do {
                    applyProfiles()
                    let standards = try references.standardSites(sites.records).map(EvaluationSite.init)
                    try evaluation.setStandardPopulation(standards,token:references.populationToken)
                    message = "\(standards.count)개 표준 건물을 적용했습니다. 원자료를 확인한 뒤 기준을 갱신하세요."
                } catch { message = error.localizedDescription }
            }.disabled(references.isBusy)
            Text("같은 주소에 유효 단지가 여러 개면 각각 하나씩, 한 단지에 주소가 여러 개면 합쳐서 하나만 선정합니다. 연결과 표준 건물이 미확인된 등록이 있으면 전체 기준 적용을 보류합니다.").font(.caption).foregroundStyle(.secondary)
            if let error = message ?? references.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
    private func applyProfiles() {
        do { try sites.applyKaptProfiles(references.profiles(sites.records.compactMap { $0.building?.building })) }
        catch { message = error.localizedDescription }
    }
}
private struct KaptPrimaryRow: View {
    @EnvironmentObject private var references: BuildingReferenceStore
    let record: KaptReferenceRecord
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(record.name); Text(record.id).font(.caption2).foregroundStyle(.secondary)
            Text(record.roads.isEmpty ? "도로명주소 미확인 또는 공란" : record.roads.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary)
            if record.hasConfirmedBlankRoad { Text("주소 공란 · 수집 제외").font(.caption).foregroundStyle(.secondary) }
            else if references.linkReview(record.id)?.conflicted == true { Text("기기 간 연결 충돌 · 다시 검증").font(.caption).foregroundStyle(.orange) }
            else if let decision = references.currentDecision(record) {
                Text(decision.disposition == .excluded ? "목록 제외 · " + decision.reason : "검증됨 · 공시가격 \(decision.realtyIDs.count)개 · 표준 건물 " + (decision.standardBuildingIdentity == nil ? "미지정" : "지정됨")).font(.caption).foregroundStyle(decision.disposition == .excluded ? Color.secondary : Color.green)
            } else { Text(references.collectionComplete(record) ? "수집됨 · 연결 검증 필요" : "수집·검증 필요").font(.caption).foregroundStyle(.orange) }
        }
    }
}
struct KaptPrimaryCollectionStatus: View {
    @ObservedObject var status: HousingCollectionStatus
    var body: some View {
        if let value = status.value {
            if let fraction = value.fraction { ProgressView(value:fraction) }
            Text(value.summary).font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from:.now,by:1)) { timeline in Text(value.estimateText(at:timeline.date)).font(.caption).foregroundStyle(.secondary) }
        }
        if !status.backgroundMessage.isEmpty { Text(status.backgroundMessage).font(.caption).foregroundStyle(.secondary) }
    }
}

struct KaptLinkReviewView: View {
    @EnvironmentObject private var references: BuildingReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject private var api = PublicDataStore.shared
    let kaptID: String
    @State private var selectedIDs = Set<String>()
    @State private var members = Set<String>()
    @State private var standard = ""
    @State private var excluding = false
    @State private var wholeScope = false
    @State private var wholePrice = false
    @State private var reason = ""
    @State private var priceKeyword = ""
    @State private var extraRoad = ""
    @State private var seeded = false
    @State private var message: String?
    private var record: KaptReferenceRecord? { references.archive.records.first { $0.id == kaptID } }
    private var buildings: [EvaluationBuilding] {
        guard let record else { return [] }
        let keys = Set(record.roads.compactMap(BuildingAddress.key))
        return (references.concordance.observations ?? []).filter { keys.contains($0.id) }.flatMap(\.buildings).sorted {
            if BuildingAddress.dongKey($0.dongName) != BuildingAddress.dongKey($1.dongName) { return BuildingAddress.dongLess($0.dongName,$1.dongName) }
            return ($0.roadKey + $0.id) < ($1.roadKey + $1.id)
        }
    }
    private var choices: [SiteTarget] {
        sites.records.filter { site in guard let selection = site.building else { return false }; return members.contains(selection.identity) && buildings.contains { $0.id == selection.building.id && $0.complexScopeKey == selection.building.complexScopeKey } }
            .sorted { BuildingAddress.dongLess($0.building!.building.dongName,$1.building!.building.dongName) }
    }
    private var prices: [HousingSource] {
        guard let record else { return [] }
        var ids = Set(references.candidates(record).map(\.id)); ids.formUnion(selectedIDs)
        if let key = BuildingAddress.key(extraRoad) { ids.formUnion(references.concordance.searches.first { $0.id == key }?.sourceIDs ?? []) }
        return references.concordance.sources.filter { source in
            ids.contains(source.id) || (!priceKeyword.isEmpty && ([source.id] + Array(source.fields.values)).joined(separator:" ").localizedCaseInsensitiveContains(priceKeyword))
        }.sorted { $0.id < $1.id }
    }
    var body: some View {
        Form {
            if let record {
                sourceSection(record)
                if !record.hasConfirmedBlankRoad {
                    linksSection(record)
                    membershipSection(record)
                    confirmationSection(record)
                }
            } else { Text("K-apt 목록을 먼저 수집하세요.") }
            if let message = message ?? references.errorMessage { Section { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) } }
        }.navigationTitle("단지 연결 검증").navigationBarTitleDisplayMode(.inline)
            .onAppear { seed() }
            .onChange(of:references.isBusy) { _,busy in if !busy, selectedIDs.isEmpty, !excluding, let record { let candidates = references.candidates(record); if candidates.count == 1 { selectedIDs = [candidates[0].id] } } }
            .onChange(of:members) { _,_ in if !choices.contains(where:{ $0.building?.identity == standard }) { standard = "" } }
            .onChange(of:selectedIDs) { _,_ in if selectedIDs.count != 1 { wholePrice = false } }
    }
    private func sourceSection(_ record: KaptReferenceRecord) -> some View {
        Section("K-apt 원본") {
            Text(record.name).bold(); Text(record.id).font(.caption).textSelection(.enabled)
            Text(record.roads.joined(separator:"\n")).font(.caption).textSelection(.enabled)
            Text(record.fields["jibunAddress",default:""]).font(.caption)
            KaptComparisonFields(fields:record.fields)
            Button("이 단지 기본·공시가격 자료 수집 이어서") { references.start(api:api,codes:[kaptID]) }.disabled(references.isBusy || api.isBusy || record.hasConfirmedBlankRoad)
            Button("이 단지 최신 자료 다시 조회") { references.start(api:api,codes:[kaptID],refresh:true) }.disabled(references.isBusy || api.isBusy || record.hasConfirmedBlankRoad)
            if references.isBusy { KaptPrimaryCollectionStatus(status:references.collectionStatus); Button("수집 중단") { references.stop() } }
            Text(references.progress).font(.caption)
            if record.hasConfirmedBlankRoad { Text("기본 정보에서 도로명주소 공란을 확인해 수집·표준 목록에서 제외했습니다. 원본은 보존합니다.").font(.caption).foregroundStyle(.secondary) }
            if let review = references.linkReview(kaptID), review.conflicted { Text("두 기기의 검증이 다릅니다. 아래 연결을 직접 확인해 저장하면 충돌 기록을 대체합니다.").font(.caption).foregroundStyle(.orange) }
            forJobEvidence(record)
        }
    }
    @ViewBuilder private func forJobEvidence(_ record: KaptReferenceRecord) -> some View {
        ForEach(record.roads,id:\.self) { road in
            if let job = references.concordance.searches.first(where:{ $0.id == BuildingAddress.key(road) }) {
                Text("\(road) · \(job.method == "road" ? "도로명검색" : "도로명 결과 없음 → 지번검색") · 후보 \(job.sourceIDs.count)개").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func linksSection(_ record: KaptReferenceRecord) -> some View {
        Section("공시가격 연결 · \(selectedIDs.count)개 선택") {
            Text("후보가 하나면 1:1로 제안합니다. 저장 전에는 미승인 상태입니다. 같은 공시가격 단지를 다른 유효한 K-apt 단지에도 연결할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            NativeTextField("보관 공시가격 원본에서 단지명·주소·코드 찾기",text:$priceKeyword).frame(minHeight:44)
            NativeTextField("추가로 검색할 정확한 도로명주소",text:$extraRoad).frame(minHeight:44)
            Button("추가 주소에서 공시가격 후보 수집") { inputs.finishEditing(); references.start(api:api,extraRoad:extraRoad) }.disabled(references.isBusy || api.isBusy || BuildingAddress.key(extraRoad) == nil)
            if prices.isEmpty { Text("후보가 없습니다. 도로명·지번 검색 수집 결과와 원본 주소를 확인하세요.").font(.caption).foregroundStyle(.orange) }
            ForEach(Array(prices.prefix(100))) { price in
                KaptPriceCandidateRow(source:price,selected:selectedIDs.contains(price.id)) { if !selectedIDs.insert(price.id).inserted { selectedIDs.remove(price.id) } }
            }
            if prices.count > 100 { Text("검색어로 후보를 좁히세요. 100개까지 표시합니다.").font(.caption) }
            if selectedIDs.count == 1 {
                Toggle("선택한 공시가격 원본이 이 관리단지 전체 범위임을 확인",isOn:$wholePrice)
                Text("여러 유효한 K-apt 단지가 이 원본을 공유하면 공시가격 전체 주차대수는 각 단지에 적용하지 않습니다.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func membershipSection(_ record: KaptReferenceRecord) -> some View {
        Section("소속 건물·표준 평가 건물") {
            ForEach(record.roads,id:\.self) { road in NavigationLink("\(road) · 개별 건물·입구 확인") { BuildingRegisterView(roadAddress:road) } }
            ForEach(buildings) { building in
                let identity = building.roadKey + "|" + building.id
                Toggle(isOn:Binding(get:{ members.contains(identity) },set:{ if $0 { members.insert(identity) } else { members.remove(identity) } })) {
                    VStack(alignment:.leading,spacing:3) {
                        Text([building.name,building.dongName].filter { !$0.isEmpty }.joined(separator:" "))
                        Text(building.roadAddress).font(.caption)
                        Text("대장 \(building.id) · 상위 \(building.parentRegistryID ?? "미확인")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if buildings.isEmpty { Text("주소에서 건축물대장과 입구를 조회한 뒤 소속 건물을 선택하세요.").font(.caption).foregroundStyle(.secondary) }
            Picker("이 단지의 표준 건물 하나",selection:$standard) {
                Text("미지정").tag("")
                ForEach(choices) { site in Text(site.name + " · " + site.address).tag(site.building!.identity) }
            }
            Text("표준은 소속을 확인하고 입구를 저장한 건물 중 하나입니다. 여러 주소를 가진 단지도 하나만 선정합니다. 같은 주소의 별개 단지는 각 소속 건물을 구분해 선정하세요.").font(.caption).foregroundStyle(.secondary)
        }.disabled(excluding)
    }
    private func confirmationSection(_ record: KaptReferenceRecord) -> some View {
        Section("직접 검증·저장") {
            Toggle("중복 또는 없어진 K-apt 등록으로 목록에서 제외",isOn:$excluding)
            if excluding { Text("공시가격 연결과 표준 선택을 해제하고 제외 사유·원본을 보존합니다. 여기서 제외를 끄고 다시 검증해 복원할 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
            else { Toggle("이 K-apt 등록이 실재하는 단지의 전체 관리범위임을 확인",isOn:$wholeScope) }
            NativeTextField("연결·유효 여부 또는 제외 사유",text:$reason).frame(minHeight:44)
            Button(excluding ? "연결 해제·목록 제외 저장" : "확인한 연결·소속·표준 건물 저장") { save(record) }.buttonStyle(.borderedProminent).disabled(references.isBusy || record.fetchedAt == nil)
        }
    }
    private func seed() {
        guard !seeded, let record else { return }; seeded = true
        if let decision = references.linkReview(kaptID)?.decision {
            selectedIDs = Set(decision.realtyIDs); members = Set(decision.memberBuildings.keys); standard = decision.standardBuildingIdentity ?? ""
            excluding = decision.disposition == .excluded; wholeScope = decision.wholeKaptScope; wholePrice = !decision.wholeRealtyIDs.isEmpty; reason = decision.reason
        } else { let candidates = references.candidates(record); if candidates.count == 1 { selectedIDs = [candidates[0].id] } }
    }
    private func save(_ record: KaptReferenceRecord) {
        do {
            inputs.finishEditing()
            let previous = references.linkReview(kaptID)?.heads ?? []
            let pricesByID = Dictionary(references.concordance.sources.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
            let buildingsByID = Dictionary(buildings.map { ($0.roadKey + "|" + $0.id,$0) },uniquingKeysWith:{ x,_ in x })
            let ids = excluding ? [] : selectedIDs.sorted()
            let keys = try Dictionary(ids.map { id -> (String,String) in guard let price = pricesByID[id] else { throw DeviceShareError.invalid }; return (id,KaptConcordance.sourceKey(price)) },uniquingKeysWith:{ x,_ in x })
            let memberKeys = try Dictionary((excluding ? [] : members.sorted()).map { id -> (String,String) in guard let building = buildingsByID[id] else { throw DeviceShareError.invalid }; return (id,building.complexScopeKey) },uniquingKeysWith:{ x,_ in x })
            let decision = KaptLinkDecision(id:UUID().uuidString,kaptID:kaptID,disposition:excluding ? .excluded : .accepted,realtyIDs:ids,
                reason:BuildingAddress.clean(reason),kaptScopeKey:record.source.scopeKey,realtyScopeKeys:keys,memberBuildings:memberKeys,
                standardBuildingIdentity:excluding || standard.isEmpty ? nil : standard,wholeKaptScope:!excluding && wholeScope,
                wholeRealtyIDs:!excluding && wholePrice && ids.count == 1 ? ids : [],supersedes:Array(Set(previous.flatMap { $0.supersedes + [$0.id] })).sorted(),updatedAt:Date())
            try references.saveLink(decision)
            try sites.applyKaptProfiles(references.profiles(sites.records.compactMap { $0.building?.building }))
            message = excluding ? "목록에서 제외했습니다. 원본·제외 기록은 보존했습니다." : "연결을 검증해 저장했습니다. 이 단지의 소속 건물 정보도 갱신했습니다."
        } catch { message = error.localizedDescription }
    }
}
private struct KaptPriceCandidateRow: View {
    let source: HousingSource
    let selected: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            Button(action:toggle) { Label(source.fields["name",default:source.id],systemImage:selected ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless)
            Text(source.id).font(.caption2).textSelection(.enabled)
            Text(BuildingFacts.blank(source.fields["roadAddress"]) ? "도로명주소 없음 · 지번 확인 필요" : source.fields["roadAddress",default:""]).font(.caption)
            Text(source.fields["jibunAddress",default:""]).font(.caption)
            KaptComparisonFields(fields:source.fields)
            Text(source.detailAt == nil ? "상세 수집 미완료" : "상세 수집됨 · 연결은 직접 확인").font(.caption2).foregroundStyle(source.detailAt == nil ? Color.orange : Color.secondary)
        }
    }
}
private struct KaptComparisonFields: View {
    let fields: [String:String]
    var body: some View {
        Text("사용승인 \(fields["approvalDate",default:"미확인"]) · 동수 \(fields["buildings",default:"미확인"]) · 세대수 \(fields["households",default:"미확인"])").font(.caption).foregroundStyle(.secondary)
        if let dongs = fields["dongNames"], !dongs.isEmpty { Text("동 목록 " + dongs).font(.caption).foregroundStyle(.secondary) }
        if let parking = fields["parking"], !parking.isEmpty { Text("주차대수 " + parking).font(.caption).foregroundStyle(.secondary) }
        if let status = fields["registrationStatus"], !status.isEmpty { Text("K-apt 사용 상태 " + status).font(.caption2).foregroundStyle(.secondary) }
    }
}
