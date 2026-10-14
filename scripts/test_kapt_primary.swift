import Foundation
import Darwin

struct TMapCoordinate: Codable, Equatable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
struct SiteTarget { var building: BuildingSelection? }
enum PlannerFailure: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }
func require(_ value: Bool, _ text: String) throws { if !value { throw PlannerFailure.message(text) } }
func rejects(_ action: () throws -> Void) throws { do { try action(); throw PlannerFailure.message("expected rejection") } catch let error as PlannerFailure { if case .message("expected rejection") = error { throw error } } catch {} }
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value) }
@main struct KaptPrimaryChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--realty-address-live") {
            do {
                let searcher = RealtyAddressSearchClient()
                let results = try await searcher.road("서울특별시 강남구 삼성로 212")
                try require(!results.isEmpty,"live exact road search returned no result")
                try require(results.allSatisfy { BuildingAddress.key($0.fields["roadAddress",default:""]) == "서울특별시 강남구 삼성로 212" },"adjacent road number leaked")
                print("PASS live production client reads one exact road-number search")
                let detail = try await searcher.client.detail(results[0]); try require(detail.detailAt != nil,"live targeted detail missing")
                print("PASS live targeted detail preserves the searched complex identity")
                print("REALTY_ADDRESS_LIVE_CHECKS 2/2"); return
            } catch { print("REALTY_ADDRESS_LIVE_UNVERIFIED " + error.localizedDescription); fflush(stdout); exit(2) }
        }
        let road = "대전광역시 서구 청사로 70", other = "대전광역시 서구 가상로 20"
        let at = Date(timeIntervalSince1970:1_791_734_400)
        var passed = 0
        func check(_ name: String, _ action: () throws -> Void) throws { try action(); passed += 1; print("PASS " + name); fflush(stdout) }
        func price(_ code: String, address: String = "", parking: String = "500") -> HousingSource {
            HousingSource(id:"realty:30170:" + code,aptCode:code,noticeDate:"20260101",regionCode:"3017011300",fields:["name":"가상 공시가격 " + code,"roadAddress":address.isEmpty ? road : address,"jibunAddress":"대전광역시 서구 월평동 301","parking":parking,"dongNames":"101동,201동","heating":"지역난방","households":"300"],detailAt:at)
        }
        func record(_ id: String, roads: [String]? = nil, parking: String = "100", households: String = "50") -> KaptReferenceRecord {
            KaptReferenceRecord(id:id,name:"가상 " + id,roadAddresses:roads ?? [road],fields:["approvalDate":"2000-01-01","households":households,"buildings":"1","jibunAddress":"대전광역시 서구 월평동 301","parking":parking,"registrationStatus":"사용","heating":"개별난방"],fetchedAt:at,facilitiesAt:at,basicSchemaVersion:2)
        }
        func building(_ id: String, dong: String = "101동", address: String = "") -> EvaluationBuilding {
            EvaluationBuilding(id:id,roadAddress:address.isEmpty ? road : address,name:"가상 건물 " + id,dongName:dong,fields:["use":"아파트","households":"20"],fetchedAt:at,parentRegistryID:"recap:" + id,parcelID:"3017011300103010000")
        }
        func selection(_ value: EvaluationBuilding) -> BuildingSelection { BuildingSelection(building:value,choice:.firstDong,entranceSource:"가상 입구 확인",entranceID:"entry:" + value.id,longitude:127.4,latitude:36.3) }
        func decision(_ value: KaptReferenceRecord, prices: [HousingSource], members: [EvaluationBuilding] = [], standard: EvaluationBuilding? = nil, id: String = UUID().uuidString) -> KaptLinkDecision {
            KaptLinkDecision(id:id,kaptID:value.id,disposition:.accepted,realtyIDs:prices.map(\.id).sorted(),reason:"가상 직접 비교·검증",kaptScopeKey:value.source.scopeKey,realtyScopeKeys:Dictionary(prices.map { ($0.id,KaptConcordance.sourceKey($0)) },uniquingKeysWith:{ a,_ in a }),memberBuildings:Dictionary(members.map { ($0.roadKey + "|" + $0.id,$0.complexScopeKey) },uniquingKeysWith:{ a,_ in a }),standardBuildingIdentity:standard.map { $0.roadKey + "|" + $0.id },wholeKaptScope:true,updatedAt:at)
        }
        func store(_ records: [KaptReferenceRecord], prices: [HousingSource] = [], observations: [KaptRegistryObservation] = []) throws -> BuildingReferenceStore {
            var data: Data? = try DeviceShareCodec.encode(BuildingReferenceArchive(listTotal:records.count,nextPage:2,listComplete:true,records:records,concordance:KaptConcordance(sources:prices,observations:observations)))
            return BuildingReferenceStore(read:{ data },write:{ data = $0 })
        }
        func observation(_ buildings: [EvaluationBuilding], address: String = "", groups: [RegistryBuildingComplex] = []) -> KaptRegistryObservation { KaptRegistryObservation(roadAddress:address.isEmpty ? road : address,buildings:buildings,groups:groups,fetchedAt:at) }
        let p1 = price("P1"), p2 = price("P2",address:other), a = record("A"), b = record("B",parking:"200",households:"100")
        let ba = building("a"), bb = building("b",dong:"201동"), bc = building("c",dong:"102동",address:other)
        let primary = try store([a,b],prices:[p1],observations:[observation([ba,bb])])
        try check("Kapt codes sharing a road remain two pending primary records") {
            try require(primary.archive.records.count == 2 && primary.catalog.addresses.count == 1 && primary.validKaptRecords.isEmpty && primary.pendingKaptRecords.count == 2,"address deduplicated primary identity")
        }
        try check("an address default never auto approves a Kapt link or standard") { try rejects { _ = try primary.standardSites([SiteTarget(building:selection(ba))]) } }
        var da = decision(a,prices:[p1],members:[ba],standard:ba)
        da.wholeRealtyIDs = [p1.id]
        try primary.saveLink(da)
        try check("default one-to-one approval persists without accepting a neighbor") { try require(primary.validKaptRecords.map(\.id) == ["A"] && primary.pendingKaptRecords.map(\.id) == ["B"],"neighbor auto approved") }
        try check("unverified remaining Kapt prevents a partial nationwide distribution") { try rejects { _ = try primary.standardSites([SiteTarget(building:selection(ba))]) } }
        try check("exclusive whole price scope may supply common parking before a second owner") { try require(primary.profile(ba)?.complex.sharedFacts["parking"]?.value == "500","whole exclusive price missing") }
        var db = decision(b,prices:[p1],members:[bb],standard:bb); db.wholeRealtyIDs = [p1.id]
        try primary.saveLink(db)
        try check("two valid Kapt sharing one price complex produce two standard buildings") {
            let standards = try primary.standardSites([SiteTarget(building:selection(ba)),SiteTarget(building:selection(bb))])
            try require(standards.count == 2 && Set(standards.compactMap { $0.building?.building.id }) == ["a","b"],"many-to-one collapsed standards")
        }
        try check("a shared price total never contaminates separate Kapt parking scopes") {
            try require(primary.profile(ba)?.complex.sharedFacts["parking"]?.value == "100" && primary.profile(bb)?.complex.sharedFacts["parking"]?.value == "200","shared price parking duplicated")
            try require(primary.profile(ba)?.complex.sharedFacts["parkingPerHousehold"]?.value == "2.0000","building households used as denominator")
        }
        try check("building registry facts remain primary despite linked apartment totals") {
            try require(primary.profile(ba)?.facts["households"]?.value == "20" && primary.profile(ba)?.facts["households"]?.source == .registry,"registry overwritten")
        }
        try check("linked price fills an apartment blank before Kapt") { try require(primary.profile(ba)?.facts["heating"]?.value == "지역난방" && primary.profile(ba)?.facts["heating"]?.source == .realty,"priority lost") }
        let multi = record("MULTI",roads:[road,other])
        let one = try store([multi],prices:[p1,p2],observations:[observation([ba]),observation([bc],address:other)])
        try one.saveLink(decision(multi,prices:[p1,p2],members:[ba,bc],standard:ba))
        try check("one Kapt with two roads and two price links has one standard") { try require(try one.standardSites([SiteTarget(building:selection(ba)),SiteTarget(building:selection(bc))]).count == 1,"multi-address expanded standards") }
        try check("multiple linked price parking values are not added or applied as whole") { try require(one.profile(ba)?.complex.sharedFacts["parking"]?.value == "100","multi-price total applied") }
        try check("a decision cannot point a standard outside its confirmed membership") { var invalid = decision(a,prices:[p1]); invalid.standardBuildingIdentity = selection(ba).identity; try rejects { try invalid.validate() } }
        try check("a decision needs a nonempty price edge and management scope") { var invalid = decision(a,prices:[]); try rejects { try invalid.validate() }; invalid = decision(a,prices:[p1]); invalid.wholeKaptScope = false; try rejects { try invalid.validate() } }
        try check("a decision needs a verification or exclusion reason") { var invalid = da; invalid.reason = " "; try rejects { try invalid.validate() } }
        try check("unknown price identities cannot be saved") { var invalid = da; invalid.id = "unknown"; invalid.realtyIDs = ["realty:30170:UNKNOWN"]; invalid.realtyScopeKeys = ["realty:30170:UNKNOWN":"x"]; invalid.wholeRealtyIDs = []; try rejects { try primary.saveLink(invalid) } }
        try check("unknown registry membership cannot be confirmed") { var invalid = da; invalid.id = "unknown-member"; invalid.memberBuildings[road + "|fake"] = "fake"; try rejects { try primary.saveLink(invalid) } }
        let beforeToken = primary.populationToken
        var excluded = KaptLinkDecision(id:"exclude-A",kaptID:a.id,disposition:.excluded,realtyIDs:[],reason:"중복으로 확인한 가상 등록",kaptScopeKey:a.source.scopeKey,realtyScopeKeys:[:],supersedes:[da.id],updatedAt:at.addingTimeInterval(1))
        try primary.saveLink(excluded)
        try check("excluding a duplicate clears links and standards while preserving both raw sources") {
            try require(primary.isExcluded(a) && primary.currentDecision(a)?.realtyIDs.isEmpty == true && primary.archive.records.count == 2 && primary.concordance.sources.count == 1,"raw deleted or link retained")
            try require(try primary.standardSites([SiteTarget(building:selection(bb))]).count == 1,"excluded Kapt retained in standard population")
        }
        try check("exclusion changes population token and withholds old building scope") { try require(primary.populationToken != beforeToken && primary.profile(ba) == nil,"excluded scope survived") }
        var restored = da; restored.id = "restore-A"; restored.supersedes = [da.id,excluded.id]; restored.updatedAt = at.addingTimeInterval(2)
        try primary.saveLink(restored)
        try check("an excluded primary row can be explicitly restored and relinked") { try require(primary.validKaptRecords.count == 2 && primary.profile(ba) != nil,"restore failed") }
        let blank = record("BLANK",roads:[" "]), unknown = KaptReferenceRecord(id:"UNKNOWN",name:"미수집",roadAddresses:[])
        let blankStore = try store([blank,unknown])
        try check("only an actually fetched blank road is skipped") { try require(blankStore.isExcluded(blank) && !blankStore.isExcluded(unknown) && blankStore.pendingKaptRecords.map(\.id) == ["UNKNOWN"],"unfetched treated as demolished") }
        try check("old archives preserve raw records and require new user links") {
            let old = BuildingReferenceArchive(listTotal:1,nextPage:2,listComplete:true,records:[a]); let data = try DeviceShareCodec.encode(old)
            let restoredStore = BuildingReferenceStore(read:{data},write:{_ in})
            try require(restoredStore.archive.records.count == 1 && restoredStore.validKaptRecords.isEmpty && restoredStore.errorMessage == nil,"old archive discarded or approved")
        }
        var changedPrice = p1; changedPrice.noticeDate = "20270101"; changedPrice.detailAt = at.addingTimeInterval(5)
        try one.mergeConcordance(KaptConcordance(sources:[changedPrice]))
        try check("a new price notice invalidates old verified link footprints") { try require(one.validKaptRecords.isEmpty && one.profile(ba) == nil,"stale link accepted") }
        var changedBuilding = bb; changedBuilding.parentRegistryID = "new-recap"
        try primary.saveObservation(observation([ba,changedBuilding]))
        try check("a changed registry parent invalidates standard membership and shared facts") { try require(primary.profile(bb) == nil,"stale parent shared"); try rejects { _ = try primary.standardSites([SiteTarget(building:selection(ba)),SiteTarget(building:selection(bb))]) } }
        let ambiguous = try store([a,b],prices:[p1],observations:[observation([ba])])
        try ambiguous.saveLink(decision(a,prices:[p1],members:[ba],standard:ba))
        try ambiguous.saveLink(decision(b,prices:[p1],members:[ba],standard:ba))
        try check("one physical building cannot silently belong to two separate valid Kapt") { try require(ambiguous.profile(ba) == nil,"shared ownership applied"); try rejects { _ = try ambiguous.standardSites([SiteTarget(building:selection(ba))]) } }
        var fork = da; fork.id = "fork"; fork.standardBuildingIdentity = nil
        let merged = try KaptLinkReview.merge(KaptLinkReview(kaptID:"A",heads:[da]),KaptLinkReview(kaptID:"A",heads:[fork]))
        try check("concurrent device decisions remain visible as a conflict") { try require(merged.conflicted && merged.decision == nil,"last-writer hid conflict") }
        var resolved = da; resolved.id = "resolved"; resolved.supersedes = [da.id,fork.id]
        let resolution = try KaptLinkReview.merge(merged,KaptLinkReview(kaptID:"A",heads:[resolved]))
        try check("explicitly superseding both device heads resolves the conflict") { try require(resolution.decision?.id == "resolved","conflict not resolved") }
        try check("same decision identity with changed content is rejected") { var tampered = da; tampered.reason = "다른 내용"; try rejects { _ = try KaptLinkReview.merge(KaptLinkReview(kaptID:"A",heads:[da]),KaptLinkReview(kaptID:"A",heads:[tampered])) } }
        try check("cross-device archive merging preserves independent many-to-many edges") {
            let left = BuildingReferenceArchive(listTotal:2,nextPage:2,listComplete:true,records:[a,b],concordance:KaptConcordance(sources:[p1],reviews:[KaptLinkReview(kaptID:"A",heads:[da])]))
            let right = BuildingReferenceArchive(listTotal:2,nextPage:2,listComplete:true,records:[a,b],concordance:KaptConcordance(sources:[p1],reviews:[KaptLinkReview(kaptID:"B",heads:[db])]))
            let combined = try BuildingReferenceArchive.merge(left,right); try require(combined.concordance?.reviews.count == 2 && combined.concordance?.sources.count == 1,"edge dropped or source doubled")
        }
        try check("completed facility checkpoint wins an equal basic timestamp") {
            var partial = a; partial.facilitiesAt = nil; partial.fields.removeValue(forKey:"parking")
            let merged = try BuildingReferenceArchive.merge(BuildingReferenceArchive(records:[partial]),BuildingReferenceArchive(records:[a]))
            try require(merged.records[0].facilitiesAt == at && merged.records[0].fields["parking"] == "100","facility progress lost")
        }
        let cached = try store([a,b,blank])
        var searches = 0, details = 0
        try await cached.collectPrices(search:{ address in searches += 1; var raw = p1; raw.detailAt = nil; return (KaptPriceSearch(roadAddress:address,method:"road",sourceIDs:[raw.id],addresses:[],fetchedAt:at),[raw]) },detail:{ source in details += 1; var full = source; full.detailAt = at; return full })
        try check("same road query and price detail are reused for separate Kapt records") { try require(searches == 1 && details == 1 && cached.concordance.searches.count == 1 && cached.validKaptRecords.isEmpty,"repeat query or automatic approval") }
        try await cached.collectPrices(search:{ _ in throw PlannerFailure.message("completed road refetched") },detail:{ _ in throw PlannerFailure.message("completed detail refetched") })
        try check("completed collection resumes without sending another query") { try require(cached.collectionComplete(a) && cached.collectionComplete(b) && cached.collectionComplete(blank),"completed job missing") }
        let empty = try store([a]); var emptyCalls = 0
        try await empty.collectPrices(search:{ address in emptyCalls += 1; return (KaptPriceSearch(roadAddress:address,method:"road+jibun",sourceIDs:[],addresses:[],fetchedAt:at),[]) },detail:{ _ in throw PlannerFailure.message("empty detail") })
        try check("no price candidate remains pending and never implies Kapt demolition") { try require(emptyCalls == 1 && empty.pendingKaptRecords.count == 1 && !empty.isExcluded(a),"empty search removed Kapt") }
        let interrupted = try store([a])
        do { try await interrupted.collectPrices(search:{ address in var raw = p1; raw.detailAt = nil; return (KaptPriceSearch(roadAddress:address,method:"road",sourceIDs:[raw.id],addresses:[],fetchedAt:at),[raw]) },detail:{ _ in throw CancellationError() }); throw PlannerFailure.message("cancel lost") } catch is CancellationError {}
        try check("cancellation persists discovered candidate and unfinished detail") { try require(interrupted.concordance.searches.count == 1 && interrupted.concordance.sources[0].detailAt == nil,"checkpoint lost") }
        try await interrupted.collectPrices(search:{ _ in throw PlannerFailure.message("saved search refetched") },detail:{ source in var full = source; full.detailAt = at; return full })
        try check("interrupted targeted source resumes from its detail checkpoint") { try require(interrupted.collectionComplete(a),"resume incomplete") }
        var requests: [[String:String]] = [], paths: [String] = []
        let scheduler = RealtyRequestScheduler(policy:RealtyRequestPolicy(minimumInterval:0),sleep:{ _ in })
        let transport: RealtyRequestScheduler.Transport = { request in
            paths.append(request.url!.path)
            let form = URLComponents(string:"https://fixture/?" + String(decoding:request.httpBody ?? Data(),as:UTF8.self))!.queryItems ?? []
            let values = Dictionary(form.map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ a,_ in a }); requests.append(values)
            let path = request.url!.path, list: [[String:Any]]
            if path.contains("getSido") { list = [["CODE":"30","NAME":"대전광역시"]] }
            else if path.contains("getSigungu") { list = [["CODE":"170","NAME":"서구"]] }
            else if path.contains("getRoadInitial") { list = [["CODE":"S","NAME":"ㅊ"]] }
            else if path.contains("getRoadTw") { list = [["CODE":"fixture-road-code","NAME":"청사로"]] }
            else {
                list = [["APT_CODE":"P1","NOTICE_DATE":"20260101","MOD_APT_NAME":"가상1","FULL_BJD_NAME":"대전광역시 서구 월평동 301","FULL_ROAD_NAME":road,"SPNU":"3017011300103010000"],
                        ["APT_CODE":"WRONG","NOTICE_DATE":"20260101","FULL_BJD_NAME":"대전광역시 서구 월평동 302","FULL_ROAD_NAME":"대전광역시 서구 청사로 72","SPNU":"3017011300103020000"]]
            }
            return (try json(["model":["list":list]]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        }
        let searcher = RealtyAddressSearchClient(client:RealtyHousingClient(scheduler:scheduler,transport:transport))
        let roadResults = try await searcher.road(road)
        try check("road search uses official detail-road mode with returned road code and number") {
            try require(requests.last?["search_gbn"] == "2" && requests.last?["search_detail_gbn"] == "1" && requests.last?["road_code"] == "fixture-road-code" && requests.last?["search_bun"] == "70" && requests.last?["eub"] == "","wrong form mode")
            try require(!paths.contains { $0.contains("getDongri") },"legal-dong discovery sent")
        }
        try check("road results exclude adjacent building numbers before any proposed link") { try require(roadResults.map(\.aptCode) == ["P1"],"adjacent building linked") }
        let before = requests.count; _ = try await searcher.road(road)
        try check("region and road metadata are cached between address lookups") { try require(requests.count == before+1,"metadata refetched") }
        try check("Hangul road initials support compound and Latin initials") { try require(RealtyAddressSearchClient.initial("청사로") == "ㅊ" && RealtyAddressSearchClient.initial("삼성로") == "ㅅ" && RealtyAddressSearchClient.initial("꽃길") == "ㄲ" && RealtyAddressSearchClient.initial("a로") == "A","initial mismatch") }
        let evidence = HousingAddressEvidence(roadAddress:road,jibunAddress:"대전광역시 서구 월평동 301",roadKey:"301703166000|0|70|0",buildingID:"fixture",dongNames:[],communityCenter:"",relatedParcels:"",fetchedAt:at,administrativeCode:"3017011300",parcelMain:"301",parcelSub:"0",mountain:"0")
        let jibunResults = try await searcher.jibun(evidence)
        try check("fallback searches one converted parcel in detail-jibun mode") { try require(jibunResults.map(\.aptCode) == ["P1"] && requests.last?["search_detail_gbn"] == "2" && requests.last?["search_bun"] == "301" && requests.last?["eub"] == "11300" && requests.last?["road_code"] == "","fallback not exact parcel") }
        try check("mountain parcels use correct PNU type and explicit mountain keyword") { var mountain = evidence; mountain.mountain = "1"; mountain.parcelSub = "2"; try require(try RealtyAddressSearchClient.parcelID(mountain) == "3017011300203010002","mountain PNU mismatch") }
        try check("incomplete converted parcel never causes a whole dong lookup") { var invalid = evidence; invalid.parcelMain = nil; try rejects { _ = try RealtyAddressSearchClient.parcelID(invalid) } }
        let emptySearcher = RealtyAddressSearchClient(client:RealtyHousingClient(scheduler:RealtyRequestScheduler(policy:RealtyRequestPolicy(minimumInterval:0),sleep:{ _ in }),transport:{ request in
            let path = request.url!.path, rows: [[String:Any]]
            if path.contains("getSido") { rows = [["CODE":"30","NAME":"대전광역시"]] }
            else if path.contains("getSigungu") { rows = [["CODE":"170","NAME":"서구"]] }
            else if path.contains("getRoadInitial") { rows = [["CODE":"S","NAME":"ㅊ"]] }
            else if path.contains("getRoadTw") { rows = [["CODE":"R","NAME":"청사로"]] }
            else { rows = [] }
            return (try json(["model":["list":rows]]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        }))
        var conversions = 0
        let fallback = try await emptySearcher.search(road,addresses:{ _ in conversions += 1; return [evidence] })
        try check("empty road search performs Juso conversion before an exact fallback") { try require(conversions == 1 && fallback.0.method == "road+jibun" && fallback.0.addresses.count == 1,"conversion not recorded") }
        conversions = 0; _ = try await searcher.search(road,addresses:{ _ in conversions += 1; return [evidence] })
        try check("successful road search spends no Juso conversion request") { try require(conversions == 0,"unnecessary Juso request") }
        let corrupt = RealtyAddressSearchClient(client:RealtyHousingClient(scheduler:RealtyRequestScheduler(policy:RealtyRequestPolicy(minimumInterval:0),sleep:{ _ in }),transport:{ request in (Data("{\"model\":{}}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!) }))
        conversions = 0
        do { _ = try await corrupt.search(road,addresses:{ _ in conversions += 1; return [evidence] }); throw PlannerFailure.message("corrupt treated empty") } catch let error as PlannerFailure { if case .message("corrupt treated empty") = error { throw error } } catch {}
        try check("malformed or blocked road requests are not treated as empty search") { try require(conversions == 0,"failure converted or hid error") }
        let snapshot = try cached.sharingSnapshot(); var replica = DeviceShareReplica(deviceID:UUID().uuidString), observed: [String:Data] = [:]
        try replica.capture(snapshot,observed:&observed); let shared = BuildingReferenceStore(read:{nil},write:{_ in}); try shared.applySharing(replica)
        try check("shared chunk checksums restore Kapt candidates and address checkpoints") { try require(shared.concordance.sources.count == 1 && shared.concordance.searches.count == 1 && shared.archive.records.count == 3,"new data not shared") }
        print("Kapt primary native checks: \(passed)/\(passed) passed")
    }
}
