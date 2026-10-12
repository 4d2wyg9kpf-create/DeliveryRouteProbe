import Foundation
import Darwin

struct TMapCoordinate: Codable, Equatable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
enum PlannerFailure: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
func require(_ value: Bool, _ text: String) throws { if !value { throw PlannerFailure.message(text) } }
func rejects(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw PlannerFailure.message("expected rejection") }
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
@MainActor final class HousingCollectionFixture: RealtyHousingCollecting {
    var areaMap: [String: [HousingArea]] = [:]
    var areaCalls: [String] = []
    var listRegion: HousingRegion?
    var listCalls = 0
    var detailCalls: [String] = []
    var failedIDs = Set<String>()
    var cancelledIDs = Set<String>()
    var onDetail: ((HousingSource) -> Void)?
    func areas(sido: String, sigungu: String) async throws -> [HousingArea] {
        let key = sido + "/" + sigungu; areaCalls.append(key); return areaMap[key] ?? []
    }
    func list(sido: HousingArea, sigungu: HousingArea, dong: HousingArea) async throws -> HousingRegion {
        listCalls += 1
        guard let region = listRegion, region.code == sido.code + sigungu.code + dong.code else { throw PlannerFailure.message("fixture list mismatch") }
        return region
    }
    func detail(_ source: HousingSource) async throws -> HousingSource {
        detailCalls.append(source.id); onDetail?(source)
        if cancelledIDs.contains(source.id) { throw CancellationError() }
        if failedIDs.contains(source.id) { throw PlannerFailure.message("fixture detail failure") }
        var value = source; value.detailAt = Date(); return value
    }
}
@main struct HousingKakaoChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ name: String, _ test: () throws -> Void) throws { try test(); passed += 1; print("PASS \(name)"); fflush(stdout) }
        let a = RouteEndpoint(id: "a", name: "단지", address: "주소", coordinate: TMapCoordinate(longitude: 127.1, latitude: 36.3))
        let b = RouteEndpoint(id: "b", name: "초등학교", address: "주소", coordinate: TMapCoordinate(longitude: 127.2, latitude: 36.4))
        let c = RouteEndpoint(id: "c", name: "공원", address: "주소", coordinate: TMapCoordinate(longitude: 127.3, latitude: 36.5))
        let now = Date(timeIntervalSince1970: 1_791_734_400)
        try check("walking uses official Kakao map endpoint and WGS84 shortest route") {
            let r = try KakaoRouteAPI.request(mode: .walk, origin: a, destinations: [b], key: "fixture", priority: "DISTANCE")
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
            try require(r.url?.host == "dapi.kakao.com" && r.url?.path == "/v2/routing/walk" && q.contains { $0.name == "route_mode" && $0.value == "SHORTEST" }, "walk endpoint")
        }
        try check("transit query has no invented future departure parameter") {
            let r = try KakaoRouteAPI.request(mode: .transit, origin: a, destinations: [b], key: "fixture", priority: "TIME", departure: now)
            try require(r.url?.path == "/v2/routing/publictraffic" && !(r.url?.query ?? "").contains("departure_time"), "transit endpoint")
        }
        try check("future driving uses Korea timezone and rejects past time") {
            let r = try KakaoRouteAPI.request(mode: .future, origin: a, destinations: [b], key: "fixture", priority: "TIME", departure: now.addingTimeInterval(3600), now: now)
            try require(r.url?.path == "/v1/future/directions" && (r.url?.query ?? "").contains(KakaoRouteAPI.departure(now.addingTimeInterval(3600))), "future time")
            try rejects { _ = try KakaoRouteAPI.request(mode: .future, origin: a, destinations: [b], key: "fixture", priority: "TIME", departure: now, now: now) }
        }
        try check("batch request reverses fixed endpoint only for multiple origins") {
            let r = try KakaoRouteAPI.request(mode: .origins, origin: b, destinations: [a,c], key: "fixture", priority: "DISTANCE")
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
            try require(r.httpMethod == "POST" && body["destination"] != nil && (body["origins"] as? [[String: Any]])?.count == 2, "batch origins")
        }
        try check("batch bounds, duplicate keys and invalid coordinates reject before dispatch") {
            try rejects { _ = try KakaoRouteAPI.request(mode: .destinations, origin: a, destinations: [b,b], key: "fixture", priority: "TIME") }
            try rejects { _ = try KakaoRouteAPI.request(mode: .car, origin: a, destinations: [], key: "fixture", priority: "TIME") }
            var bad = a; bad.coordinate.latitude = 90
            try rejects { _ = try KakaoRouteAPI.request(mode: .car, origin: bad, destinations: [b], key: "fixture", priority: "TIME") }
            try rejects { _ = try KakaoRouteAPI.request(mode: .origins, origin: a, destinations: (0..<31).map { RouteEndpoint(id: String($0), name: "", address: "", coordinate: b.coordinate) }, key: "fixture", priority: "TIME") }
        }
        try check("walk response distance and time are returned without straight line substitution") {
            let data = try json(["status": "OK", "route": ["properties": ["totalDistance": 4025, "totalTime": 3914]]])
            let result = try KakaoRouteAPI.parse(data, mode: .walk, origin: a, destinations: [b], priority: "DISTANCE")
            try require(result[0].distanceMeters == 4025 && result[0].durationSeconds == 3914, "walk values")
        }
        try check("transit alternatives retain independent distances and durations") {
            let data = try json(["status": "OK", "routes": [["properties": ["type": "BUS", "totalDistance": 1200, "totalTime": 300]], ["properties": ["type": "SUBWAY", "totalDistance": 2500, "totalTime": 200]]]])
            let results = try KakaoRouteAPI.parse(data, mode: .transit, origin: a, destinations: [b], priority: "TIME")
            try require(results.count == 2 && results[0].distanceMeters == 1200 && results[1].alternative == "SUBWAY", "transit alternatives")
        }
        try check("out of order batch responses match endpoint keys and isolate failures") {
            let data = try json(["routes": [["key": "c", "result_code": 0, "summary": ["distance": 400, "duration": 200]], ["key": "a", "result_code": 104, "result_msg": "경로 없음"]]])
            let results = try KakaoRouteAPI.parse(data, mode: .origins, origin: b, destinations: [a,c], priority: "DISTANCE")
            try require(results[0].origin.id == "c" && results[0].destination.id == "b" && results[1].distanceMeters == nil && results[1].issue != nil, "batch key matching")
        }
        try check("missing batch rows are explicit failures and unknown keys reject") {
            let data = try json(["routes": [["key": "b", "result_code": 0, "summary": ["distance": 4, "duration": 2]]]])
            let results = try KakaoRouteAPI.parse(data, mode: .destinations, origin: a, destinations: [b,c], priority: "TIME")
            try require(results.count == 2 && results[1].issue == "응답 누락", "missing row")
            try rejects { _ = try KakaoRouteAPI.parse(data, mode: .origins, origin: b, destinations: [a,c], priority: "TIME") }
        }
        try check("bad distances and explicit walk failure never become successful records") {
            try rejects { _ = try KakaoRouteAPI.parse(try json(["status": "NO_RESULTS"]), mode: .transit, origin: a, destinations: [b], priority: "TIME") }
            try rejects { _ = try KakaoRouteAPI.parse(try json(["route": ["properties": ["totalDistance": true, "totalTime": 1]]]), mode: .walk, origin: a, destinations: [b], priority: "TIME") }
        }
        let detail = try String(contentsOfFile: "tests/fixtures/realty-detail.html", encoding: .utf8), basis = try String(contentsOfFile: "tests/fixtures/realty-basis.html", encoding: .utf8)
        let source = HousingSource(id: "realty:11680:20432271", aptCode: "20432271", noticeDate: "20260626", regionCode: "1168010300", fields: ["name": "T&K개포(TK개포)"])
        var parsed = try RealtyHousingClient.parseBasis(basis, source: RealtyHousingClient.parseDetail(detail, source: source))
        parsed.detailAt = Date(timeIntervalSince1970: 1_900_000_000)
        try check("actual mobile detail separates buildings households date and use") {
            try require(parsed.fields["buildings"] == "1" && parsed.fields["households"] == "13" && parsed.fields["approvalDate"] == "2022-02-07" && parsed.fields["use"] == "다세대", "detail fields")
        }
        try check("actual basis keeps first elementary school parking and separate floors") {
            try require(parsed.fields["school"] == "서울포이초" && parsed.fields["parking"] == "6" && parsed.fields["highestFloor"] == "5" && parsed.fields["lowestFloor"] == "2", "basis fields")
        }
        try check("areas floor decimals and remove repeated integer part") { try require(parsed.fields["areas"] == "26, 28, 30, 31, 32", "integer areas") }
        try check("administrative prefix is not mistaken for a road address") { try require(parsed.fields["roadAddress"] == "" && parsed.fields["jibunAddress"] == "서울특별시 강남구 개포동 1198-2", "missing road") }
        try check("source map projection agrees with the source's Proj4 transform") {
            let points: [(Double,Double,Double,Double)] = [(204287.575165678,441473.492823977,127.04926075091029,37.47543442515722),(238000,317000,127.42414608236756,36.353080274084796),(150000,200000,126.45109688989228,35.29810867531292),(370000,600000,128.96001728697144,38.88717116288498)]
            for (x,y,lon,lat) in points { let v = RealtyCoordinateProjection.convert(x: x,y: y)!; try require(abs(v.longitude-lon) < 0.000002 && abs(v.latitude-lat) < 0.000002, "projection mismatch") }
        }
        try check("negative mobile northing in Jeju remains a valid coordinate") {
            let html = detail.replacingOccurrences(of: "204287.575165678", with: "180000").replacingOccurrences(of: "441473.492823977", with: "-30000")
            let value = try RealtyHousingClient.parseDetail(html, source: source)
            try require(abs((value.coordinate?.latitude ?? 0)-33.22575291699372) < 0.000002, "Jeju negative coordinate omitted")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("housing-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = HousingStore(directory: folder,seedIfEmpty:false)
        var region = HousingRegion(code: "1168010300", sido: HousingArea(code: "11", name: "서울특별시"), sigungu: HousingArea(code: "680", name: "강남구"), dong: HousingArea(code: "10300", name: "개포동"), generation: 1_900_000_000_000, sourceCount: 1, records: [parsed])
        try catalog.importRegion(region)
        try check("recollection refreshes original while preserving only user edited fields") {
            try catalog.edit(catalog.complexes[0], fields: ["name": "가공 단지", "parking": "8"])
            region.records[0].fields["name"] = "새 원본명"; region.records[0].fields["households"] = "15"; region.generation = 1_900_000_000_001; try catalog.importRegion(region)
            let value = catalog.complexes[0]; try require(value.name == "가공 단지" && value.fields["parking"] == "8" && value.fields["households"] == "15" && value.original?.fields["name"] == "새 원본명", "override precedence")
        }
        try check("two processed complexes can refer to the same original and hide survives recollection") {
            let original = catalog.complexes[0]; _ = try catalog.add(name: "분리 단지", regionCode: region.code, coordinate: b.coordinate, sourceIDs: original.sourceIDs)
            try require(catalog.complexes.count == 2 && catalog.complexes.allSatisfy { $0.sourceIDs == [parsed.id] }, "N-to-N source mapping")
            try catalog.hide(original); region.generation = 1_900_000_000_002; try catalog.importRegion(region)
            try require(catalog.complexes.count == 1 && HousingStore(directory: folder,seedIfEmpty:false).complexes.count == 1, "hide resurrected")
        }
        try check("shared edits transfer without requiring source recollection") {
            var replica = DeviceShareReplica(deviceID: UUID().uuidString), observed: [String: Data] = [:]
            try replica.capture(catalog.sharingSnapshot(), observed: &observed)
            let copy = HousingStore(directory: folder.appendingPathComponent("device-b"),seedIfEmpty:false); try copy.importRegion(region); try copy.applySharing(replica)
            try require(copy.complexes.count == 1 && copy.complexes[0].name == "분리 단지", "shared edits lost")
        }
        try check("source count mismatch and unsupported catalog version reject") {
            var bad = region; bad.sourceCount = 2; try rejects { try bad.validate() }
            bad = region; bad.version = 2; try rejects { try bad.validate() }
        }
        var secure: Data?, requests = 0, stateFails = false
        let mock: (URLRequest) async throws -> (Data, URLResponse) = { request in
            if request.httpMethod == "HEAD" { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Date": "Sun, 11 Oct 2026 10:00:00 GMT"])!) }
            requests += 1
            return (try json(["status": "OK", "route": ["properties": ["totalDistance": 500, "totalTime": 400]]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        let api = KakaoRouteStore(read: { secure }, write: { if stateFails { throw PlannerFailure.message("disk") }; secure = $0 }, transport: mock, directory: folder.appendingPathComponent("routes"))
        try api.saveSettings(key: "fixture_key_1234567890", mapFree: true, naviFree: true)
        _ = try await api.query(mode: .walk, fixed: a, others: [b], priority: "TIME", radius: 10000, departure: nil)
        try check("native request reserves usage and persists returned endpoint coordinates") {
            try require(requests == 1 && api.used(.walk) == 1 && api.results[0].origin.coordinate == a.coordinate, "native reservation or result missing")
        }
        stateFails = true
        do { _ = try await api.query(mode: .walk, fixed: a, others: [b], priority: "TIME", radius: 10000, departure: nil); throw PlannerFailure.message("storage failure dispatched") } catch {}
        try check("storage failure prevents a paid API request") { try require(requests == 1, "dispatch before durable reservation") }
        stateFails = false
        try api.raiseUsage(.walk, used: 1000)
        do { _ = try await api.query(mode: .walk, fixed: a, others: [b], priority: "TIME", radius: 10000, departure: nil); throw PlannerFailure.message("quota dispatched") } catch {}
        try check("free limit blocks without sending another request and survives reload") {
            let restored = KakaoRouteStore(read: { secure }, write: { secure = $0 }, transport: mock, directory: folder.appendingPathComponent("routes"))
            try require(requests == 1 && restored.used(.walk) == 1000 && restored.results.count == 1, "quota reset or result missing")
        }
        try check("editing either endpoint marks saved distance stale") {
            var updated = a; updated.coordinate.longitude += 0.000001
            try require(api.results[0].matches([a,b]) && !api.results[0].matches([updated,b]), "stale distance not detected")
        }
        try check("partial collection merges completed complex data from an older region snapshot") {
            var left = region, right = region
            left.records[0].detailAt = Date(timeIntervalSince1970: 100); left.generation = 1_900_000_000_004
            right.records[0].detailAt = Date(timeIntervalSince1970: 200); right.records[0].fields["parking"] = "12"; right.generation = 1_900_000_000_003
            let combined = try left.merging(right)
            try require(combined.records[0].fields["parking"] == "12" && combined.generation == left.generation, "older region's newer complex lost")
        }
        try check("unbounded result archive retains earlier rows outside recent display window") {
            let archive = try KakaoDistanceArchive(directory: folder.appendingPathComponent("large-results"))
            var rows: [KakaoDistanceRecord] = []
            for i in 0..<5001 { var r = api.results[0]; r.id = "result-\(i)"; r.queriedAt = Date(timeIntervalSince1970: Double(i)); rows.append(r) }
            try archive.append(rows)
            try require(archive.count == 5001 && archive.recent().count == 5000, "old distances discarded")
            let csv = folder.appendingPathComponent("all-distances.csv"); try archive.exportCSV(to: csv)
            let text = try String(contentsOf: csv,encoding: .utf8)
            try require(text.components(separatedBy: "\r\n").count == 5003 && text.contains("result-0"), "full export omitted older records")
        }
        try check("an unconfigured device cannot overwrite an existing shared Kakao credential") {
            var replica = DeviceShareReplica(deviceID: UUID().uuidString), observed: [String: Data] = [:]
            try replica.capture(api.sharingSnapshot(), observed: &observed)
            var secondState: Data?
            let empty = KakaoRouteStore(read: { nil }, write: { secondState = $0 }, transport: mock, directory: folder.appendingPathComponent("blank-device"))
            let snapshot = try empty.sharingSnapshot()
            try require(snapshot.values["setting/kakao"] == nil, "empty bootstrap exports a key deletion")
            var fresh = DeviceShareReplica(deviceID: UUID().uuidString); fresh.counter = 9000
            var blankObserved: [String: Data] = [:]; try fresh.capture(snapshot, observed: &blankObserved); try fresh.merge(replica)
            try empty.applySharing(fresh)
            try require(!empty.settings.key.isEmpty && secondState != nil, "shared credential lost")
        }
        func notice(_ id: String, _ dongs: String, households: String, parking: String) -> HousingSource {
            HousingSource(id:"realty:11680:"+id,aptCode:id,noticeDate:"20260626",regionCode:"1168010300",
                fields:["name":"시험단지 "+id,"roadAddress":"서울특별시 강남구 개포로 264","jibunAddress":"서울특별시 강남구 개포동 1282","dongNames":dongs,"buildings":String(dongs.components(separatedBy:",").count),"households":households,"parking":parking,"approvalDate":"1994-10-31","highestFloor":"20","lowestFloor":"5","areas":"59.9, 84.8"],detailAt:Date(),dongScopeConfirmed:true)
        }
        let p1 = notice("p1","101동, 102동",households:"100",parking:"120")
        let p2 = notice("p2","103동, 104동",households:"200",parking:"240")
        let p3 = notice("p3","201동, 202동",households:"80",parking:"90")
        var joined = region; joined.records = [p1,p2,p3]; joined.sourceCount = 3; joined.generation += 10
        try check("connected dong numbers remain review candidates until the user merges") {
            try require(HousingIdentity.connected(p1,p2) && !HousingIdentity.connected(p1,p3),"dong prefix rule")
            let values = HousingCatalog.effective(regions:[joined],edits:[])
            try require(values.count == 3 && values.first { $0.sourceIDs.contains(p1.id) }?.fields["households"] == "100","unapproved automatic grouping")
        }
        try check("missing dong membership and a gap never imply a connected complex") {
            var missing = p2; missing.dongScopeConfirmed = false
            var gap = p2; gap.fields["dongNames"] = "105동, 106동"
            try require(!HousingIdentity.connected(p1,missing) && !HousingIdentity.connected(p1,gap),"uncertain membership merged")
        }
        try check("whole and part scopes never double-count parking or households") {
            var full = p1; full.id = "realty:11680:full"; full.fields["dongNames"] = "101동,102동,103동,104동"; full.fields["households"] = "300"; full.fields["parking"] = "360"
            let f = HousingAggregation.fields([p1,p2,full])
            try require(f["households"] == "300" && f["parking"] == "360" && f["parkingPerHousehold"] == "1.2000","whole added to parts")
        }
        try check("positive part facility evidence survives an unknown whole registration without inventing totals") {
            var whole = p1; whole.id = "kapt:1168010300:WHOLE"; whole.fields["elevators"] = ""; whole.fields["chargerGround"] = "미확인"; whole.fields["chargerUnderground"] = "미확인"
            var part = p2; part.id = "kapt:1168010300:PART"; part.dongScopeConfirmed = false; part.fields["elevators"] = "2"; part.fields["chargerUnderground"] = "있음"
            let result = HousingAggregation.fields([p1,p2,whole,part],preferredKaptID:whole.id)
            try require(result["elevatorPresent"] == "있음" && result["chargerPresent"] == "있음" && result["elevators"] == "","positive evidence lost or unconfirmed count guessed")
        }
        try check("different categorical dates addresses and areas survive a lossless merge") {
            var other = p2; other.fields["heating"] = "개별난방"; other.fields["approvalDate"] = "1995-01-01"; other.fields["roadAddress"] = "서울특별시 강남구 개포로 266"; other.fields["highestFloor"] = "25"; other.fields["lowestFloor"] = "3"; other.fields["areas"] = "59.2, 99.1"
            var first = p1; first.fields["heating"] = "지역난방"
            let f = HousingAggregation.fields([first,other])
            try require(f["heating"] == "지역난방\n개별난방" && f["approvalDate"]?.contains("1995-01-01") == true && f["roadAddress"]?.contains("266") == true && f["areas"] == "59, 84, 99" && f["highestFloor"] == "25" && f["lowestFloor"] == "3","details lost")
        }
        try check("partial overlap produces an unresolved total rather than a guessed sum") {
            var partial = p2; partial.fields["dongNames"] = "102동,103동"; partial.fields["parking"] = "200"
            try require(HousingAggregation.fields([p1,partial])["parking"] == "","partial overlap guessed")
        }
        let kaptSource = HousingSource(id:"kapt:1168010300:A30279105",aptCode:"A30279105",noticeDate:"",regionCode:"1168010300",fields:[:])
        let basic = try json(["response":["header":["resultCode":"00"],"body":["item":["kaptCode":"A30279105","kaptName":"누리아파트","doroJuso":"대전광역시 서구 청사로 70","kaptAddr":"대전광역시 서구 월평동 301 누리아파트","codeSaleNm":"분양","codeHeatNm":"지역난방","codeHallNm":"계단식","kaptDongCnt":16,"kaptdaCnt":"1704","kaptUsedate":"19941031","kaptTel":"0424853697"]]]])
        let facilities = try json(["response":["header":["resultCode":"00"],"body":["item":["kaptCode":"A30279105","codeWsupply":"부스터방식","kaptdEcnt":60,"kaptdPcnt":563,"kaptdPcntu":1586,"groundElChargerCnt":0,"undergroundElChargerCnt":2,"useYn":"Y"]]]])
        let nuri = try KaptHousingClient.detail(basic:basic,facilities:facilities,source:kaptSource)
        try check("current K-apt V5 data maps the seven requested fields and derives same-scope parking") {
            try require(nuri.fields["saleType"] == "분양" && nuri.fields["heating"] == "지역난방" && nuri.fields["corridor"] == "계단식" && nuri.fields["waterSupply"] == "부스터방식" && nuri.fields["elevators"] == "60" && nuri.fields["parking"] == "2149" && nuri.fields["parkingPerHousehold"] == "1.2612" && nuri.fields["chargerPresent"] == "있음" && nuri.rawData != nil,"K-apt extraction")
        }
        try check("unknown elevator and charger values stay unknown while one positive flag wins") {
            var f:[String:String] = ["chargerGround":"미확인","chargerUnderground":"있음","households":"0","parking":"100"]
            HousingAggregation.derive(&f)
            try require(f["chargerPresent"] == "있음" && f["elevatorPresent"] == "미확인" && f["parkingPerHousehold"] == "","unknown converted to zero")
            f["chargerUnderground"] = "없음"; HousingAggregation.derive(&f); try require(f["chargerPresent"] == "미확인","unknown charger became absent")
        }
        try check("K-apt code mismatches and XML gateway quota errors reject") {
            try rejects { _ = try KaptHousingClient.info(basic,code:"different") }
            do { _ = try KaptGateway.body(Data("<OpenAPI_ServiceResponse><cmmMsgHeader><returnReasonCode>22</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>".utf8)); throw PlannerFailure.message("quota accepted") }
            catch PublicDataFailure.provider(let code) { try require(code == "22","XML quota code lost") }
        }
        try check("K-apt list XML singleton and an empty legal dong parse without JSON assumptions") {
            let xml = "<response><header><resultCode>00</resultCode></header><body><items><item><kaptCode>A1</kaptCode><kaptName>단지</kaptName><bjdCode>1168010300</bjdCode></item></items><pageNo>1</pageNo><numOfRows>100</numOfRows><totalCount>1</totalCount></body></response>"
            try require(try KaptHousingClient.list(Data(xml.utf8),region:"1168010300",page:1).records.count == 1,"XML singleton")
            let empty = try json(["response":["header":["resultCode":"00"],"body":["items":[],"totalCount":0,"pageNo":1]]])
            try require(try KaptHousingClient.list(empty,region:"1168010300",page:1).records.isEmpty,"empty list")
        }
        try check("current API paths and ServiceKey casing preserve literal plus signs") {
            let list = try KaptGateway.request(.list,key:"key+with/slash=",parameters:["bjdCode":"1168010300","pageNo":"1"])
            let detail = try KaptGateway.request(.facilities,key:"fixture",parameters:["kaptCode":"A1"])
            try require(list.url?.path == "/1613000/AptListService4/getLegaldongAptList4" && list.url!.absoluteString.contains("%2B") && detail.url?.query?.contains("ServiceKey=") == true,"API URL/key encoding")
        }
        let addressJSON = try json(["results":["common":["errorCode":"0","totalCount":"1"],"juso":[["roadAddrPart1":"대전광역시 서구 청사로 70","jibunAddr":"대전광역시 서구 월평동 301","rnMgtSn":"301703166000","udrtYn":"0","buldMnnm":"70","buldSlno":"0","bdMgtSn":"301701130010301000000001","detBdNmList":"101동,102동","hemdNm":"월평2동 행정복지센터","relJibun":"301-1"]]]])
        try check("address API stores structured identity center and building names as unconfirmed coverage") {
            let reader = HousingAddressClient(transport:{ request in (addressJSON,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!) })
            // Parsing itself does not establish management-area membership.
            let address = try HousingAddressClient.parse(addressJSON).addresses[0]
            try require(address.communityCenter == "월평2동 행정복지센터" && address.dongNames.count == 2 && address.roadKey == "301703166000|0|70|0","address evidence")
            _ = reader
        }
        let addressReader = HousingAddressClient(transport:{ request in (addressJSON,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!) })
        let enriched = try await addressReader.lookup(nuri,key:"fixture_address_key")
        try check("address-wide dong names never become a K-apt ownership assertion") { try require(enriched.dongScopeConfirmed != true && enriched.fields["jusoDongNames"] == "101동\n102동" && enriched.fields["communityCenter"] == "월평2동 행정복지센터","inferred management scope") }
        try check("different approval dates and multiple management registrations prevent ambiguous automatic linking") {
            var matching = p1; matching.fields["buildings"] = "16"; matching.fields["households"] = "1704"; matching.fields["roadAddress"] = nuri.fields["roadAddress"]; matching.fields["jibunAddress"] = nuri.fields["jibunAddress"]
            var duplicate = nuri; duplicate.id += "duplicate"
            try require(HousingIdentity.certainMatch(matching,nuri,realtyPeers:[matching],kaptPeers:[nuri]),"unique match not corrected")
            try require(!HousingIdentity.certainMatch(matching,nuri,realtyPeers:[matching],kaptPeers:[nuri,duplicate]),"same-address management ambiguity")
            matching.fields["approvalDate"] = "2020-01-01"
            try require(!HousingIdentity.certainMatch(matching,nuri,realtyPeers:[matching],kaptPeers:[nuri]),"old K-apt applied to redevelopment")
        }
        let mergeStore = HousingStore(directory:folder.appendingPathComponent("kapt-integration"),seedIfEmpty:false)
        var manual = joined; manual.records = [p1,p3]; manual.sourceCount = 2
        var fullKapt = nuri; fullKapt.fields["name"] = "둔산이편한세상"; fullKapt.fields["parking"] = "700"; fullKapt.fields["households"] = "180"; fullKapt.fields["buildings"] = "4"
        var partKapt = fullKapt; partKapt.aptCode = "PART1"; partKapt.id = "kapt:1168010300:PART1"; partKapt.fields["name"] = "둔산이편한세상1단지"; partKapt.fields["parking"] = "120"
        manual.kaptRecords = [fullKapt,partKapt]; try mergeStore.importRegion(manual)
        try check("collecting matching K-apt originals never attaches or merges without confirmation") {
            try require(mergeStore.complexes.count == 2 && mergeStore.complexes.allSatisfy { $0.originals.allSatisfy { !$0.isKapt } },"automatic K-apt attachment")
            var matching = fullKapt; matching.fields["roadAddress"] = p1.fields["roadAddress"]; matching.fields["jibunAddress"] = p1.fields["jibunAddress"]; matching.fields["buildings"] = p1.fields["buildings"]; matching.fields["households"] = p1.fields["households"]
            var exact = manual; exact.records = [p1]; exact.sourceCount = 1; exact.kaptRecords = [matching]
            try require(HousingCatalog.effective(regions:[exact],edits:[])[0].originals.count == 1,"even exact match attached without consent")
            let candidates = try mergeStore.reviewCandidates(mergeStore.complexes[0])
            try require(candidates.count == 2,"same-address review candidates missing")
        }
        try check("manual merging keeps every original instead of blanking fields and can be undone") {
            try mergeStore.merge(Set(mergeStore.complexes.map(\.id)),name:"통합 단지")
            let combined = mergeStore.complexes[0]
            try require(mergeStore.complexes.count == 1 && combined.originals.count == 2 && combined.fields["areas"] == "59, 84" && combined.fields["approvalDate"] == "1994-10-31","manual merge lost details")
            try mergeStore.reset(combined.id); try require(mergeStore.complexes.count == 2,"undo failed")
        }
        try mergeStore.merge(Set(mergeStore.complexes.map(\.id)),name:"전체 평가 단지")
        let selectedComplex = mergeStore.complexes[0]
        try mergeStore.attachKapt(selectedComplex,sourceIDs:[fullKapt.id,partKapt.id],wholeID:fullKapt.id,useWholeName:true)
        try check("explicit whole K-apt selection retains partial provenance without summing duplicate totals") {
            let value = mergeStore.complexes.first { $0.id == selectedComplex.id }!
            try require(value.name == "둔산이편한세상" && value.fields["parking"] == "700" && value.originals.count == 4 && mergeStore.complexes.count == 1,"whole-plus-part doubled or provenance lost")
        }
        try mergeStore.saveSourceOverride(fullKapt,fields:["heating":"사용자 보정"],confirmedDongs:false)
        fullKapt.fields["heating"] = "새 수집값"; fullKapt.detailAt = Date().addingTimeInterval(60); manual.kaptRecords = [fullKapt,partKapt]; manual.generation += 20; try mergeStore.importRegion(manual)
        try check("source-specific corrections survive new K-apt data and a reload") {
            let reload = HousingStore(directory:folder.appendingPathComponent("kapt-integration"),seedIfEmpty:false)
            try require(reload.complexes.first { $0.id == selectedComplex.id }?.fields["heating"]?.contains("사용자 보정") == true,"correction overwritten")
        }
        try mergeStore.saveAddressKey("fixture_address_key")
        var housingReplica = DeviceShareReplica(deviceID:UUID().uuidString), housingObserved:[String:Data] = [:]
        try housingReplica.capture(mergeStore.sharingSnapshot(),observed:&housingObserved)
        let receiving = HousingStore(directory:folder.appendingPathComponent("kapt-receiver"),seedIfEmpty:false); try receiving.importRegion(manual); try receiving.applySharing(housingReplica)
        try check("K-apt links source corrections and address keys share while blank devices export no key deletion") {
            try require(receiving.hasAddressKey && receiving.complexes.first { $0.id == selectedComplex.id }?.fields["parking"] == "700","shared integration lost")
            let blank = HousingStore(directory:folder.appendingPathComponent("blank-housing"),seedIfEmpty:false); try require(try blank.sharingSnapshot().values["setting/housing-address"] == nil,"empty key deletion")
        }
        try check("next-year list refresh preserves old detail and manual links while only new IDs need details") {
            let before = mergeStore.complexes.first { $0.id == selectedComplex.id }!
            try mergeStore.edit(before,fields:["name":"내가 수정한 단지명"])
            var annual = manual
            annual.records = manual.records.map { row in
                var listed = row; listed.noticeDate = "20270101"; listed.detailAt = nil
                listed.fields = ["name":"내년도 목록명","roadAddress":row.fields["roadAddress"] ?? "","jibunAddress":row.fields["jibunAddress"] ?? ""]
                return listed
            }
            var new = notice("new-2027","301동",households:"10",parking:"12"); new.noticeDate = "20270101"; new.detailAt = nil
            annual.records.append(new); annual.sourceCount = 3; annual.generation += 100; annual.listFetchedMillis = annual.generation
            try mergeStore.importRegion(annual)
            let saved = try mergeStore.originalRegion(annual.code)
            let value = mergeStore.complexes.first { $0.id == selectedComplex.id }!
            try require(saved.missingDetailIDs == [new.id] && saved.records.first { $0.id == p1.id }?.latestNoticeDate == "20270101","old records scheduled again")
            try require(value.name == "내가 수정한 단지명" && value.fields["parking"] == "700" && value.originals.count == 4 && mergeStore.complexes.count == 2,"recollection duplicated or changed group")
            annual = saved; let position = annual.records.firstIndex { $0.id == p1.id }!
            annual.records[position].fields["school"] = "새 초등학교"; annual.records[position].noticeDate = "20270101"; annual.records[position].detailAt = Date().addingTimeInterval(120); annual.generation += 100
            try mergeStore.importRegion(annual); try mergeStore.importRegion(annual)
            let reload = HousingStore(directory:folder.appendingPathComponent("kapt-integration"),seedIfEmpty:false)
            let refreshed = reload.complexes.first { $0.id == selectedComplex.id }!
            try require(reload.complexes.count == 2 && refreshed.name == "내가 수정한 단지명" && refreshed.fields["school"] == "새 초등학교","explicit refresh duplicated or erased edits")
        }
        try check("nested merges retain earlier manual values and restore the previous grouping") {
            let nested = HousingStore(directory:folder.appendingPathComponent("nested-merges"),seedIfEmpty:false)
            try nested.importRegion(joined); try nested.merge([p1.id,p2.id],name:"처음 통합명")
            let first = nested.complexes.first { $0.id.hasPrefix("user:") }!
            try nested.edit(first,fields:["heating":"직접 보정한 난방","parking":"390"])
            try nested.merge(Set(nested.complexes.map(\.id)),name:"최종 통합명")
            let final = nested.complexes[0]
            try require(nested.complexes.count == 1 && final.originals.count == 3 && final.fields["heating"] == "직접 보정한 난방" && final.fields["parking"] == "480","earlier group overrides lost")
            try require(final.priorEdits.contains { $0.fields["name"] == "처음 통합명" },"previous names not retained")
            try nested.reset(final.id)
            try require(nested.complexes.count == 2 && nested.complexes.first { $0.id == first.id }?.fields["parking"] == "390","nested undo lost edits")
        }
        try check("regional storage keeps all rows while bounded display reads only the search window") {
            let many = HousingStore(directory:folder.appendingPathComponent("more-than-2000"),seedIfEmpty:false)
            var wide = joined
            wide.records = (0..<2005).map { n in var row = notice("wide-\(n)","101동",households:"10",parking:"12"); row.fields["name"] = "단지 \(String(format:"%04d",n))"; return row }
            wide.sourceCount = wide.records.count; try many.importRegion(wide)
            try require(try many.originalRegion(wide.code).records.count == 2005 && many.complexes.count == 2000,"display cap truncated stored catalog")
        }
        var collectionState: Data?, collectionRequests = 0, listHasNew = false
        let collectionAPI = PublicDataStore(read:{ collectionState },write:{ collectionState = $0 },transport:{ request in
            if request.httpMethod == "HEAD" { return (Data(),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Date":"Sun, 11 Oct 2026 10:00:00 GMT"])!) }
            collectionRequests += 1
            let path = request.url!.path, query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            let code = query.first { $0.name == "kaptCode" }?.value ?? "A30279105"
            let data: Data
            if path.contains("getLegaldong") {
                var rows = [["kaptCode":"A30279105","kaptName":"시험 등록","bjdCode":"1168010300"]]
                if listHasNew { rows.append(["kaptCode":"NEW2","kaptName":"추가 등록","bjdCode":"1168010300"]) }
                data = try json(["response":["header":["resultCode":"00"],"body":["items":rows,"pageNo":1,"totalCount":rows.count]]])
            } else {
                let template = path.contains("getAphusBass") ? basic : facilities
                data = Data(String(decoding:template,as:UTF8.self).replacingOccurrences(of:"A30279105",with:code).utf8)
            }
            return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        })
        try require(collectionAPI.saveSettings(key:"fixture-key",approved:["kaptList","kaptBasis"],limits:["kaptList":20,"kaptBasis":20]),"collector settings")
        let collector = HousingStore(directory:folder.appendingPathComponent("incremental-kapt"),seedIfEmpty:false)
        var collectionRegion = manual; collectionRegion.kaptRecords = nil; collectionRegion.kaptListAt = nil; try collector.importRegion(collectionRegion)
        try await collector.collectKapt(manual.code,refresh:false,api:collectionAPI)
        try await collector.collectKapt(manual.code,refresh:false,api:collectionAPI)
        listHasNew = true; try await collector.collectKapt(manual.code,refresh:false,api:collectionAPI)
        try check("repeated K-apt collection queries only missing detail while retaining originals and explicit grouping") {
            let stored = try collector.originalRegion(manual.code)
            try require(collectionRequests == 7 && stored.kaptRecords?.count == 2 && stored.kaptRecords?.allSatisfy { $0.detailAt != nil } == true && collector.complexes.count == 2,"existing K-apt details fetched again or sources duplicated")
        }
        var publicState: Data?, publicRequests = 0
        let gateway = PublicDataStore(read:{ publicState },write:{ publicState = $0 },transport:{ request in
            if request.httpMethod == "HEAD" { return (Data(),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Date":"Sun, 11 Oct 2026 10:00:00 GMT"])!) }
            publicRequests += 1; return (basic,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        })
        try require(gateway.saveSettings(key:"fixture-key",approved:[PublicDataService.kaptBasis.rawValue],limits:[PublicDataService.kaptBasis.rawValue:1]),"public settings")
        _ = try await gateway.kaptData(.basic,parameters:["kaptCode":"A30279105"])
        do { _ = try await gateway.kaptData(.facilities,parameters:["kaptCode":"A30279105"]); throw PlannerFailure.message("quota dispatched") } catch {}
        try check("basic and facility requests reserve the same durable quota before dispatch") { try require(publicRequests == 1 && gateway.quotas.first { $0.id == .kaptBasis }?.used == 1,"shared K-apt quota") }
        let s1 = HousingArea(code: "11", name: "시도1"), s2 = HousingArea(code: "26", name: "시도2")
        let g1 = HousingArea(code: "680", name: "시군구1"), g2 = HousingArea(code: "110", name: "시군구2")
        let d1 = HousingArea(code: "10300", name: "법정동1"), d2 = HousingArea(code: "11000", name: "법정동2")
        let areas = HousingCollectionFixture()
        areas.areaMap = ["/": [s1,s2], "11/": [g1], "26/": [g2], "11/680": [d1,d1], "26/110": [d2]]
        let provinceTargets = try await HousingCollectionTargets.resolve(.province(s1), client: areas)
        try check("province selection collects its child dongs without querying another province") {
            try require(provinceTargets.map(\.id) == ["1168010300"] && areas.areaCalls == ["11/","11/680"], "province scope or duplicate target")
        }
        areas.areaCalls = []
        let districtTargets = try await HousingCollectionTargets.resolve(.district(s1,g1), client: areas)
        try check("district selection collects only that district's child dongs") {
            try require(districtTargets.map(\.id) == ["1168010300"] && areas.areaCalls == ["11/680"], "district scope")
        }
        areas.areaCalls = []
        let dongTargets = try await HousingCollectionTargets.resolve(.dong(s1,g1,d1), client: areas)
        try check("single dong selection uses its known target without redundant area queries") {
            try require(dongTargets.count == 1 && areas.areaCalls.isEmpty, "dong scope")
        }
        areas.areaCalls = []
        let nationwideTargets = try await HousingCollectionTargets.resolve(.nationwide, client: areas)
        try check("nationwide targets are discovered without any prior apartment list collection") {
            try require(nationwideTargets.map(\.id) == ["1168010300","2611011000"] && areas.listCalls == 0, "nationwide enumeration depended on saved apartment lists")
        }
        try check("discovery has no invented percentage and the scope denominator stays frozen") {
            var progress = HousingCollectionProgress(scopeTitle:"전국",includesDetails:true)
            progress.discovered(1); try require(progress.fraction == nil && progress.percentage == nil,"premature completion rate")
            progress.setTargets(nationwideTargets.map(\.id)); progress.setTargets(["unrelated"])
            progress.beginRegion(id:nationwideTargets[0].id,title:"첫 지역"); progress.regionFinished(successful:true)
            progress.beginRegion(id:nationwideTargets[1].id,title:"둘째 지역"); progress.regionFinished(successful:false)
            progress.finish()
            try require(progress.targetRegionIDs?.count == 2 && progress.fraction == 0.5 && progress.failedRegionIDs.count == 1,"scope total changed or failed region marked complete")
        }
        try check("large incomplete scope cannot round up to 100 percent") {
            var progress = HousingCollectionProgress(scopeTitle:"전국",includesDetails:true)
            let ids = (0..<5000).map(String.init); progress.setTargets(ids)
            for id in ids.dropLast() { progress.beginRegion(id:id,title:id); progress.regionFinished(successful:true) }
            try require(progress.percentage == "99.9%", "rounded unfinished collection to 100%")
        }
        var realtyList = manual; realtyList.kaptRecords = nil; realtyList.kaptListAt = nil
        realtyList.records = ["z-last","a-first","m-middle"].map { apt in
            var row = manual.records[0]; row.aptCode = apt; row.id = "realty:" + manual.code.prefix(5) + ":" + apt
            row.detailAt = nil; row.fields["roadAddress"] = "서울 강남구 가상로 1"; return row
        }
        realtyList.sourceCount = realtyList.records.count
        let realty = HousingCollectionFixture(); realty.listRegion = realtyList
        let realtyTarget = HousingCollectionTarget(sido:realtyList.sido,sigungu:realtyList.sigungu,dong:realtyList.dong)
        let realtyStore = HousingStore(directory:folder.appendingPathComponent("realty-progress"),seedIfEmpty:false)
        realtyStore.collectionProgress = HousingCollectionProgress(scopeTitle:"전국",includesDetails:true)
        realtyStore.updateCollectionProgress { $0.setTargets([realtyTarget.id]) }
        var beforeCounts: [Int] = [], denominators: [Int] = []
        realty.onDetail = { _ in
            beforeCounts.append(realtyStore.collectionProgress!.detailCompletedCount)
            denominators.append(realtyStore.collectionProgress!.detailTotalCount!)
        }
        let completeRealty = try await realtyStore.collectRealtyRegion(realtyTarget,details:true,client:realty)
        try check("same-dong detail numerator advances sequentially despite source sorting during save") {
            try require(completeRealty && beforeCounts == [0,1,2] && denominators == [3,3,3] && realtyStore.collectionProgress?.detailCompletedCount == 3,"record index leaked into completion count")
            try require(try realtyStore.originalRegion(realtyTarget.id).detailCount == 3,"count advanced before successful persistence")
        }
        var added = realtyList.records[0]; added.aptCode = "b-new"; added.id = "realty:" + manual.code.prefix(5) + ":b-new"
        realtyList.records.append(added); realtyList.sourceCount = realtyList.records.count; realty.listRegion = realtyList
        beforeCounts = []; denominators = []; let previousCalls = realty.detailCalls.count
        realtyStore.collectionProgress = HousingCollectionProgress(scopeTitle:"선택 시도",includesDetails:true)
        realtyStore.updateCollectionProgress { $0.setTargets([realtyTarget.id]) }
        _ = try await realtyStore.collectRealtyRegion(realtyTarget,details:true,client:realty)
        try check("one combined collection action detects new rows and skips all completed details") {
            try require(realty.detailCalls.count == previousCalls + 1 && beforeCounts == [3] && denominators == [4] && realtyStore.collectionProgress?.detailCompletedCount == 4,"existing detail refetched or resumed count restarted")
        }
        let failureStore = HousingStore(directory:folder.appendingPathComponent("realty-progress-failure"),seedIfEmpty:false)
        let failing = HousingCollectionFixture(); failing.listRegion = realty.listRegion; failing.failedIDs = [added.id]
        failureStore.collectionProgress = HousingCollectionProgress(scopeTitle:"시군구",includesDetails:true)
        failureStore.updateCollectionProgress { $0.setTargets([realtyTarget.id]) }
        let completeFailed = try await failureStore.collectRealtyRegion(realtyTarget,details:true,client:failing)
        failureStore.updateCollectionProgress { $0.regionFinished(successful:completeFailed); $0.finish() }
        try check("failed detail is retained as pending and never inflates either completion numerator") {
            try require(!completeFailed && failureStore.collectionProgress?.detailCompletedCount == 3 && failureStore.collectionProgress?.detailTotalCount == 4 && failureStore.collectionProgress?.failedDetailIDs.count == 1 && failureStore.collectionProgress?.fraction == 0,"failed attempt counted as completed")
        }
        let stopStore = HousingStore(directory:folder.appendingPathComponent("realty-progress-stop"),seedIfEmpty:false)
        let stopping = HousingCollectionFixture(); stopping.listRegion = realtyList; stopping.cancelledIDs = [realtyList.records[1].id]
        stopStore.collectionProgress = HousingCollectionProgress(scopeTitle:"법정동",includesDetails:true)
        stopStore.updateCollectionProgress { $0.setTargets([realtyTarget.id]) }
        do { _ = try await stopStore.collectRealtyRegion(realtyTarget,details:true,client:stopping); throw PlannerFailure.message("ignored cancellation") }
        catch is CancellationError { stopStore.updateCollectionProgress { $0.stop() } }
        try check("stopping collection keeps successful detail and does not claim completion") {
            try require(try stopStore.originalRegion(realtyTarget.id).detailCount == 1 && stopStore.collectionProgress?.detailCompletedCount == 1 && stopStore.collectionProgress?.fraction == 0,"stop discarded records or marked scope complete")
        }
        stopping.cancelledIDs = []; let previousStopCalls = stopping.detailCalls.count
        stopStore.collectionProgress = HousingCollectionProgress(scopeTitle:"법정동",includesDetails:true)
        stopStore.updateCollectionProgress { $0.setTargets([realtyTarget.id]) }
        let resumed = try await stopStore.collectRealtyRegion(realtyTarget,details:true,client:stopping)
        try check("combined action resumes after stop with a stable whole-region detail denominator") {
            try require(resumed && stopping.detailCalls.count == previousStopCalls + 3 && stopStore.collectionProgress?.detailCompletedCount == 4 && stopStore.collectionProgress?.detailTotalCount == 4,"resume repeated completed detail or changed denominator")
        }
        let callsBeforeListOnly = realty.detailCalls.count
        _ = try await realtyStore.collectRealtyRegion(realtyTarget,details:false,client:realty)
        try check("list-only confirmation stays separate and never requests detail") {
            try require(realty.detailCalls.count == callsBeforeListOnly,"list-only action requested detail")
        }
        print("Housing Kakao native checks: \(passed)/\(passed) passed")
    }
}
