import Foundation

struct HousingArea: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var id: String { code }
}
enum HousingField: String, CaseIterable, Identifiable {
    case name, roadAddress, jibunAddress, dongNames, buildings, households, approvalDate, use, school, parking, highestFloor, lowestFloor, areas
    case saleType, heating, corridor, waterSupply, elevators, elevatorPresent, parkingPerHousehold, chargerGround, chargerUnderground, chargerPresent, communityCenter, managementOffice
    var id: String { rawValue }
    var title: String {
        switch self { case .name: return "단지명"; case .roadAddress: return "도로명주소"; case .jibunAddress: return "지번주소"; case .dongNames: return "동 번호 · 동 명칭"; case .buildings: return "동수"; case .households: return "세대수"; case .approvalDate: return "사용승인일"; case .use: return "용도"; case .school: return "첫 초등학교 · 통합 시 원본별 보존"; case .parking: return "전체 주차대수"; case .highestFloor: return "최고층"; case .lowestFloor: return "최저층"; case .areas: return "공시면적 종류(m² · 정수)"; case .saleType: return "분양형태"; case .heating: return "난방방식"; case .corridor: return "복도유형"; case .waterSupply: return "급수방식"; case .elevators: return "승강기대수"; case .elevatorPresent: return "승강기 유무"; case .parkingPerHousehold: return "세대당 주차대수"; case .chargerGround: return "전기충전기 설치 · 지상"; case .chargerUnderground: return "전기충전기 설치 · 지하"; case .chargerPresent: return "전기충전기 설치 여부"; case .communityCenter: return "관할 주민센터"; case .managementOffice: return "관리사무소 연락처" }
    }
    var derived: Bool { [.elevatorPresent, .parkingPerHousehold, .chargerPresent].contains(self) }
}
struct HousingAddressEvidence: Codable {
    var roadAddress: String
    var jibunAddress: String
    var roadKey: String
    var buildingID: String
    var dongNames: [String]
    var communityCenter: String
    var relatedParcels: String
    var fetchedAt: Date
    var administrativeCode: String? = nil
    var parcelMain: String? = nil
    var parcelSub: String? = nil
    var mountain: String? = nil
}
struct HousingSource: Codable, Identifiable {
    var id: String
    var aptCode: String
    var noticeDate: String
    var latestNoticeDate: String? = nil
    var regionCode: String
    var fields: [String: String]
    var coordinate: TMapCoordinate?
    var detailAt: Date?
    var issues: [String] = []
    var dongScopeConfirmed: Bool? = nil
    var addresses: [HousingAddressEvidence]? = nil
    var rawData: Data? = nil
    // Index-only materialized groups. Regional files retain every raw source.
    var members: [HousingSource]? = nil
    var isKapt: Bool { id.hasPrefix("kapt:") }
    var originals: [HousingSource] { members ?? [self] }
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
    var kaptRecords: [HousingSource]? = nil
    var kaptListAt: Date? = nil
    var id: String { code }
    var title: String { "\(sido.name) \(sigungu.name) \(dong.name)" }
    var detailCount: Int { records.filter { $0.detailAt != nil }.count }
    var missingDetailIDs: [String] { records.filter { $0.detailAt == nil }.map(\.id) }
    func validate() throws {
        guard version == 1, code.range(of: #"^\d{10}$"#, options: .regularExpression) != nil,
              code == sido.code + sigungu.code + dong.code, listFetchedMillis.map({ $0.isFinite && $0 > 0 && $0 <= generation + 60_000 }) ?? true, generation.isFinite, generation > 0, generation <= 9_000_000_000_000_000,
              sourceCount == records.count, records.count <= 100_000, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ $0.id == "realty:" + code.prefix(5) + ":" + $0.aptCode && $0.regionCode == code && Self.validSource($0) }),
              (kaptRecords?.count ?? 0) <= 100_000,
              Set((kaptRecords ?? []).map(\.id)).count == (kaptRecords?.count ?? 0),
              (kaptRecords ?? []).allSatisfy({ $0.id == "kapt:" + code + ":" + $0.aptCode && $0.regionCode == code && Self.validSource($0) }) else { throw PlannerFailure.message("공동주택 원본 자료의 지역·개수·식별자를 확인하세요.") }
    }
    static func validSource(_ s: HousingSource) -> Bool {
        s.members == nil && s.fields.count <= 100 && s.fields.values.allSatisfy { $0.utf8.count <= 20_000 } &&
        (s.rawData?.count ?? 0) <= 1_000_000 && (s.addresses?.count ?? 0) <= 100 &&
        (s.coordinate.map(KakaoRouteAPI.valid) ?? true) && (s.addresses ?? []).allSatisfy { a in
            a.dongNames.count <= 2_000 && a.dongNames.allSatisfy { $0.utf8.count <= 200 } && a.roadKey.utf8.count <= 200 && a.roadAddress.utf8.count <= 2_000 && a.jibunAddress.utf8.count <= 2_000 && a.relatedParcels.utf8.count <= 20_000
        }
    }
}
struct HousingEdit: Codable, Identifiable {
    var id: String
    var sourceIDs: [String]
    var regionCode: String
    var fields: [String: String] = [:]
    var coordinate: TMapCoordinate?
    var hidden = false
    var preferredKaptID: String? = nil
    var note: String? = nil
    var dongScopeConfirmed: Bool? = nil
    var mergedIDs: [String]? = nil
    var sourceExcluded: Bool? = nil
}
struct HousingComplex: Identifiable {
    var id: String
    var sourceIDs: [String]
    var regionCode: String
    var fields: [String: String]
    var coordinate: TMapCoordinate?
    var original: HousingSource?
    var edited: Bool
    var originals: [HousingSource] = []
    var priorEdits: [HousingEdit] = []
    var name: String { fields[HousingField.name.rawValue] ?? "이름 없음" }
    var address: String { let road = fields[HousingField.roadAddress.rawValue] ?? ""; return (road.isEmpty ? fields[HousingField.jibunAddress.rawValue] ?? "" : road).components(separatedBy: "\n").first ?? "" }
    var searchText: String { fields.values.joined(separator: " ") }
}
enum HousingCatalog {
    static func effective(regions: [HousingRegion], edits: [HousingEdit]) -> [HousingComplex] {
        effective(sources: regions.flatMap { HousingConsolidator.sources($0) + ($0.kaptRecords ?? []) }, edits: edits)
    }
    static func effective(sources incoming: [HousingSource], edits: [HousingEdit]) -> [HousingComplex] {
        let roots = incoming.filter { !$0.isKapt }
        let sources = Dictionary(incoming.flatMap(\.originals).map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let overrides = Dictionary(edits.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let owners = Dictionary(roots.flatMap { root in (root.members ?? []).filter { $0.id != root.id }.map { ($0.id, root.id) } }, uniquingKeysWith: { first, _ in first })
        let covered = Set(edits.filter { !$0.hidden && $0.id.hasPrefix("user:") && $0.sourceIDs.count > 1 }.flatMap(\.sourceIDs))
        let coveredGroups = Set(edits.filter { !$0.hidden }.flatMap { $0.mergedIDs ?? [] })
        let rootMap = Dictionary(roots.filter { owners[$0.id] == nil || $0.members != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(rootMap.keys).union(overrides.keys.filter { $0.hasPrefix("user:") })
        func history(_ id: String, seen: Set<String> = []) -> [HousingEdit] {
            guard seen.count < 64, !seen.contains(id), let edit = overrides[id] else { return [] }
            let visited = seen.union([id])
            return (edit.mergedIDs ?? []).compactMap { overrides[$0] }.flatMap { [$0] + history($0.id,seen:visited) }
        }
        func adjusted(_ rows: [HousingSource]) -> [HousingSource] {
            rows.compactMap { row in
                let edit = overrides[row.id]
                if edit?.sourceExcluded == true { return nil }
                var next = row; next.fields.merge(edit?.fields ?? [:]) { _,user in user }
                if let scope = edit?.dongScopeConfirmed { next.dongScopeConfirmed = scope }; return next
            }
        }
        func fieldsFor(_ edit: HousingEdit, rows: [HousingSource], seen: Set<String> = []) -> [String:String] {
            var fields = HousingAggregation.fields(rows,preferredKaptID:edit.preferredKaptID)
            if seen.count < 64, !seen.contains(edit.id), let children = edit.mergedIDs, !children.isEmpty {
                let previous = children.compactMap { overrides[$0] }
                let parts = previous.map { child -> HousingSource in
                    let memberRows = adjusted(child.sourceIDs.compactMap { sources[$0] })
                    let summary = fieldsFor(child,rows:memberRows,seen:seen.union([edit.id]))
                    return HousingSource(id:child.id,aptCode:child.id,noticeDate:"",regionCode:child.regionCode,fields:summary,
                        dongScopeConfirmed:!memberRows.filter { !$0.isKapt }.isEmpty && memberRows.filter { !$0.isKapt }.allSatisfy { HousingIdentity.numbers($0) != nil })
                }
                let inherited = Set((previous + history(edit.id)).flatMap { $0.fields.keys }).subtracting(["name","elevatorPresent","parkingPerHousehold","chargerPresent"])
                for key in inherited {
                    if ["buildings","households","parking","elevators"].contains(key) {
                        if edit.preferredKaptID == nil || !["parking","elevators"].contains(key) { fields[key] = HousingAggregation.summed(key,parts) }
                    } else if ["highestFloor","lowestFloor","areas"].contains(key) {
                        fields[key] = HousingAggregation.fields(parts)[key]
                    } else { fields[key] = HousingAggregation.union(parts.compactMap { $0.fields[key] }) }
                }
            }
            fields.merge(edit.fields) { _,user in user }; HousingAggregation.derive(&fields); return fields
        }
        return ids.compactMap { id in
            let source = rootMap[id], edit = overrides[id]
            guard edit?.hidden != true, !coveredGroups.contains(id) else { return nil }
            var originals = edit?.sourceIDs.compactMap { sources[$0] } ?? source?.originals ?? []
            if !id.hasPrefix("user:") { originals.removeAll { covered.contains($0.id) }; guard originals.contains(where: { !$0.isKapt }) else { return nil } }
            let rawOriginals = originals
            originals = adjusted(originals)
            let original = rawOriginals.first { !$0.isKapt } ?? rawOriginals.first
            let fields = edit.map { fieldsFor($0,rows:originals) } ?? HousingAggregation.fields(originals)
            return HousingComplex(id: id, sourceIDs: edit?.sourceIDs ?? rawOriginals.map(\.id), regionCode: edit?.regionCode ?? source?.regionCode ?? "",
                fields: fields, coordinate: edit?.coordinate ?? original?.coordinate, original: original, edited: edit != nil, originals: rawOriginals,priorEdits:history(id))
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
            guard let a = local[row.id], let b = remote[row.id] else { return row }
            return Self.newerSource(a,b)
        }
        // A new announcement refreshes list identity, not every saved detail.
        // Missing old rows are retained for review rather than silently removed.
        let listed = Set(latest.records.map(\.id))
        latest.records.append(contentsOf:(records + incoming.records).filter { !listed.contains($0.id) }.reduce(into:[String:HousingSource]()) { result,row in
            result[row.id] = result[row.id].map { Self.newerSource($0,row) } ?? row
        }.values)
        latest.records.sort { $0.id < $1.id }; latest.sourceCount = latest.records.count
        latest.listFetchedMillis = max(localList,remoteList)
        let supplements = (kaptRecords ?? []) + (incoming.kaptRecords ?? [])
        latest.kaptRecords = Dictionary(supplements.map { ($0.id, $0) }, uniquingKeysWith: Self.newerSource).values.sorted { $0.id < $1.id }
        latest.kaptListAt = [kaptListAt, incoming.kaptListAt].compactMap { $0 }.max()
        latest.generation = max(generation,incoming.generation)
        return latest
    }
    static func newerSource(_ a: HousingSource, _ b: HousingSource) -> HousingSource {
        let chosen = (b.detailAt ?? .distantPast) >= (a.detailAt ?? .distantPast) ? b : a
        var next = chosen
        next.latestNoticeDate = [a.latestNoticeDate,a.noticeDate,b.latestNoticeDate,b.noticeDate].compactMap { $0 }.filter { !$0.isEmpty }.max()
        let addresses = (a.addresses ?? []) + (b.addresses ?? [])
        next.addresses = Dictionary(addresses.map { ($0.buildingID + $0.roadKey, $0) }, uniquingKeysWith: { x,y in y.fetchedAt >= x.fetchedAt ? y : x }).values.sorted { $0.roadKey < $1.roadKey }
        return next
    }
}
