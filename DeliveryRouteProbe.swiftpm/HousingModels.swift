import Foundation

struct HousingArea: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var id: String { code }
}
enum HousingField: String, CaseIterable, Identifiable {
    case name, roadAddress, jibunAddress, buildings, households, approvalDate, use, school, parking, highestFloor, lowestFloor, areas
    var id: String { rawValue }
    var title: String {
        switch self { case .name: return "단지명"; case .roadAddress: return "도로명주소"; case .jibunAddress: return "지번주소"; case .buildings: return "동수"; case .households: return "세대수"; case .approvalDate: return "사용승인일"; case .use: return "용도"; case .school: return "첫 초등학교"; case .parking: return "전체 주차대수"; case .highestFloor: return "최고층"; case .lowestFloor: return "최저층"; case .areas: return "공시면적 종류(m² · 정수)" }
    }
}
struct HousingSource: Codable, Identifiable {
    var id: String
    var aptCode: String
    var noticeDate: String
    var regionCode: String
    var fields: [String: String]
    var coordinate: TMapCoordinate?
    var detailAt: Date?
    var issues: [String] = []
}
struct HousingRegion: Codable, Identifiable {
    var version = 1
    var code: String
    var sido: HousingArea
    var sigungu: HousingArea
    var dong: HousingArea
    var generation: Double
    var sourceCount: Int
    var records: [HousingSource]
    var listFetchedMillis: Double? = nil
    var id: String { code }
    var title: String { "\(sido.name) \(sigungu.name) \(dong.name)" }
    var detailCount: Int { records.filter { $0.detailAt != nil }.count }
    func validate() throws {
        guard version == 1, code.range(of: #"^\d{10}$"#, options: .regularExpression) != nil,
              code == sido.code + sigungu.code + dong.code, listFetchedMillis.map({ $0.isFinite && $0 > 0 && $0 <= generation + 60_000 }) ?? true, generation.isFinite, generation > 0, generation <= 9_000_000_000_000_000,
              sourceCount == records.count, records.count <= 100_000, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ $0.id == "realty:" + code.prefix(5) + ":" + $0.aptCode && $0.regionCode == code && $0.fields.count <= 30 && $0.fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) && ($0.coordinate.map(KakaoRouteAPI.valid) ?? true) }) else { throw PlannerFailure.message("공동주택 원본 자료의 지역·개수·식별자를 확인하세요.") }
    }
}
struct HousingEdit: Codable, Identifiable {
    var id: String
    var sourceIDs: [String]
    var regionCode: String
    var fields: [String: String] = [:]
    var coordinate: TMapCoordinate?
    var hidden = false
}
struct HousingComplex: Identifiable {
    var id: String
    var sourceIDs: [String]
    var regionCode: String
    var fields: [String: String]
    var coordinate: TMapCoordinate?
    var original: HousingSource?
    var edited: Bool
    var name: String { fields[HousingField.name.rawValue] ?? "이름 없음" }
    var address: String { let road = fields[HousingField.roadAddress.rawValue] ?? ""; return road.isEmpty ? fields[HousingField.jibunAddress.rawValue] ?? "" : road }
}
enum HousingCatalog {
    static func effective(regions: [HousingRegion], edits: [HousingEdit]) -> [HousingComplex] {
        effective(sources: regions.flatMap(\.records), edits: edits)
    }
    static func effective(sources incoming: [HousingSource], edits: [HousingEdit]) -> [HousingComplex] {
        let sources = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let overrides = Dictionary(edits.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let ids = Set(sources.keys).union(overrides.keys)
        return ids.compactMap { id in
            let source = sources[id], edit = overrides[id]
            guard edit?.hidden != true else { return nil }
            let original = source ?? edit?.sourceIDs.compactMap { sources[$0] }.first
            var fields = original?.fields ?? [:]; fields.merge(edit?.fields ?? [:]) { _, user in user }
            return HousingComplex(id: id, sourceIDs: edit?.sourceIDs ?? [id], regionCode: edit?.regionCode ?? source?.regionCode ?? "",
                fields: fields, coordinate: edit?.coordinate ?? original?.coordinate, original: original, edited: edit != nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension HousingRegion {
    func merging(_ incoming: HousingRegion) throws -> HousingRegion {
        try validate(); try incoming.validate(); guard code == incoming.code else { throw DeviceShareError.invalid }
        let localList = listFetchedMillis ?? generation, remoteList = incoming.listFetchedMillis ?? incoming.generation
        var latest = remoteList >= localList ? incoming : self
        let local = Dictionary(records.map { ($0.id,$0) }, uniquingKeysWith: { _, new in new })
        let remote = Dictionary(incoming.records.map { ($0.id,$0) }, uniquingKeysWith: { _, new in new })
        latest.records = latest.records.map { row in
            guard let a = local[row.id], let b = remote[row.id], a.noticeDate == b.noticeDate else { return row }
            if let ad = a.detailAt, let bd = b.detailAt { return bd >= ad ? b : a }
            if a.detailAt != nil { return a }; if b.detailAt != nil { return b }; return row
        }
        latest.listFetchedMillis = max(localList,remoteList)
        latest.generation = max(generation,incoming.generation)
        return latest
    }
}
