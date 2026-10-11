import Foundation

struct TMapCoordinate: Codable, Equatable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
enum PlannerFailure: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
func require(_ value: Bool, _ text: String) throws { if !value { throw PlannerFailure.message(text) } }
func rejects(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw PlannerFailure.message("expected rejection") }
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
@main struct HousingKakaoChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ name: String, _ test: () throws -> Void) throws { try test(); passed += 1; print("PASS \(name)") }
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
        let parsed = try RealtyHousingClient.parseBasis(basis, source: RealtyHousingClient.parseDetail(detail, source: source))
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("housing-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = HousingStore(directory: folder)
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
            try require(catalog.complexes.count == 1 && HousingStore(directory: folder).complexes.count == 1, "hide resurrected")
        }
        try check("shared edits transfer without requiring source recollection") {
            var replica = DeviceShareReplica(deviceID: UUID().uuidString), observed: [String: Data] = [:]
            try replica.capture(catalog.sharingSnapshot(), observed: &observed)
            let copy = HousingStore(directory: folder.appendingPathComponent("device-b")); try copy.importRegion(region); try copy.applySharing(replica)
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
        print("Housing Kakao native checks: \(passed)/\(passed) passed")
    }
}
