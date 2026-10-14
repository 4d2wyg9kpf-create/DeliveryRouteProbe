import Foundation

// K-apt is the primary identity. Addresses are search keys, and price-notice
// identities form independently reviewed many-to-many edges.
enum KaptLinkDisposition: String, Codable { case accepted, excluded }
struct KaptLinkDecision: Codable, Equatable, Identifiable {
    var id: String
    var kaptID: String
    var disposition: KaptLinkDisposition
    var realtyIDs: [String]
    var reason: String
    var kaptScopeKey: String
    var realtyScopeKeys: [String:String]
    var memberBuildings: [String:String] = [:] // building identity -> registry scope
    var standardBuildingIdentity: String? = nil
    var wholeKaptScope = false
    var wholeRealtyIDs: [String] = []
    var supersedes: [String] = []
    var updatedAt: Date
    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 200, !kaptID.isEmpty, kaptID.utf8.count <= 40,
              !BuildingFacts.blank(reason), reason.utf8.count <= 10_000,
              kaptScopeKey.utf8.count <= 100_000, realtyIDs.count <= 1_000,
              Set(realtyIDs).count == realtyIDs.count, realtyIDs.allSatisfy({ $0.hasPrefix("realty:") && $0.utf8.count <= 200 }),
              realtyScopeKeys.count <= 1_000, Set(realtyScopeKeys.keys) == Set(realtyIDs),
              realtyScopeKeys.values.allSatisfy({ $0.utf8.count <= 100_000 }),
              memberBuildings.count <= 5_000, memberBuildings.keys.allSatisfy({ $0.utf8.count <= 2_500 }),
              memberBuildings.values.allSatisfy({ $0.utf8.count <= 20_000 }),
              Set(wholeRealtyIDs).isSubset(of:Set(realtyIDs)), supersedes.count <= 5_000,
              !supersedes.contains(id), updatedAt.timeIntervalSince1970.isFinite else { throw DeviceShareError.invalid }
        if disposition == .accepted {
            guard !realtyIDs.isEmpty, wholeKaptScope,
                  standardBuildingIdentity.map({ memberBuildings[$0] != nil }) ?? true else {
                throw BuildingEvaluationError.message("유효한 단지는 공시가격 연결과 전체 관리범위를 확인하세요. 표준 건물은 소속 확인한 건물 중 하나를 선택하세요.")
            }
        } else {
            guard realtyIDs.isEmpty, memberBuildings.isEmpty, standardBuildingIdentity == nil, wholeRealtyIDs.isEmpty else {
                throw BuildingEvaluationError.message("제외할 K-apt 등록에는 연결·표준 건물을 남기지 않습니다.")
            }
        }
    }
}
struct KaptLinkReview: Codable, Equatable, Identifiable {
    var kaptID: String
    var heads: [KaptLinkDecision]
    var id: String { kaptID }
    var decision: KaptLinkDecision? { heads.count == 1 ? heads.first : nil }
    var conflicted: Bool { heads.count > 1 }
    func validate() throws {
        guard !kaptID.isEmpty, kaptID.utf8.count <= 40, !heads.isEmpty, heads.count <= 20,
              Set(heads.map(\.id)).count == heads.count, heads.allSatisfy({ $0.kaptID == kaptID }) else { throw DeviceShareError.invalid }
        for head in heads { try head.validate() }
        let ids = Set(heads.map(\.id))
        guard heads.allSatisfy({ Set($0.supersedes).isDisjoint(with:ids) }) else { throw DeviceShareError.invalid }
    }
    static func merge(_ a: Self, _ b: Self) throws -> Self {
        try a.validate(); try b.validate(); guard a.id == b.id else { throw DeviceShareError.invalid }
        var values = Dictionary(a.heads.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        for head in b.heads {
            if let old = values[head.id], old != head { throw BuildingEvaluationError.message("동일 연결 기록의 내용이 달라 원본을 보존했습니다.") }
            values[head.id] = head
        }
        let retired = Set(values.values.flatMap(\.supersedes))
        let result = Self(kaptID:a.id,heads:values.values.filter { !retired.contains($0.id) }.sorted { $0.id < $1.id })
        try result.validate(); return result
    }
}
struct KaptPriceSearch: Codable, Identifiable {
    var roadAddress: String
    var method: String // road or road+jibun
    var sourceIDs: [String]
    var addresses: [HousingAddressEvidence]
    var fetchedAt: Date
    var id: String { BuildingAddress.key(roadAddress) ?? "" }
    func validate() throws {
        guard !id.isEmpty, ["road","road+jibun"].contains(method), sourceIDs.count <= 5_000,
              Set(sourceIDs).count == sourceIDs.count, sourceIDs.allSatisfy({ $0.hasPrefix("realty:") && $0.utf8.count <= 200 }),
              addresses.count <= 100, fetchedAt.timeIntervalSince1970.isFinite else { throw DeviceShareError.invalid }
        let check = HousingSource(id:"address-check",aptCode:"",noticeDate:"",regionCode:"",fields:[:],addresses:addresses)
        guard HousingRegion.validSource(check), addresses.allSatisfy({ BuildingAddress.key($0.roadAddress) == id }) else { throw DeviceShareError.invalid }
    }
}
struct KaptRegistryObservation: Codable, Identifiable {
    var roadAddress: String
    var buildings: [EvaluationBuilding]
    var groups: [RegistryBuildingComplex]
    var fetchedAt: Date
    var id: String { BuildingAddress.key(roadAddress) ?? "" }
    func validate() throws {
        guard !id.isEmpty, buildings.count <= 5_000, groups.count <= 1_000,
              Set(buildings.map(\.id)).count == buildings.count, Set(groups.map(\.id)).count == groups.count else { throw DeviceShareError.invalid }
        for building in buildings { try building.validate(); guard building.roadKey == id else { throw DeviceShareError.invalid } }
        for group in groups {
            guard !group.id.isEmpty, group.id.utf8.count <= 200, group.name.utf8.count <= 500,
                  group.fields.count <= 100, group.fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) else { throw DeviceShareError.invalid }
        }
    }
}
struct KaptConcordance: Codable {
    var searches: [KaptPriceSearch] = []
    var sources: [HousingSource] = []
    var reviews: [KaptLinkReview] = []
    var observations: [KaptRegistryObservation]? = nil
    func validate(references: Bool = true) throws {
        guard searches.count <= 100_000, sources.count <= 200_000, reviews.count <= 100_000,
              Set(searches.map(\.id)).count == searches.count, Set(sources.map(\.id)).count == sources.count,
              Set(reviews.map(\.id)).count == reviews.count else { throw DeviceShareError.invalid }
        for search in searches { try search.validate() }
        for review in reviews { try review.validate() }
        for source in sources {
            guard source.regionCode.range(of:#"^\d{10}$"#,options:.regularExpression) != nil,
                  !source.aptCode.isEmpty, source.aptCode.utf8.count <= 100,
                  source.id == "realty:" + source.regionCode.prefix(5) + ":" + source.aptCode,
                  source.members == nil, HousingRegion.validSource(source) else { throw DeviceShareError.invalid }
        }
        let observations = observations ?? []
        guard observations.count <= 100_000, Set(observations.map(\.id)).count == observations.count, observations.reduce(0,{ $0 + $1.buildings.count }) <= 1_000_000 else { throw DeviceShareError.invalid }
        for observation in observations { try observation.validate() }
        let ids = Set(sources.map(\.id))
        guard !references || (searches.allSatisfy({ Set($0.sourceIDs).isSubset(of:ids) }) && reviews.flatMap(\.heads).allSatisfy({ Set($0.realtyIDs).isSubset(of:ids) })) else { throw DeviceShareError.invalid }
    }
    static func sourceKey(_ source: HousingSource) -> String {
        let scope = BuildingComplexSource(id:source.id,name:source.fields["name",default:""],roadAddresses:BuildingAddress.split(source.fields["roadAddress",default:""]),jibunAddress:source.fields["jibunAddress",default:""],fields:source.fields,fetchedAt:source.detailAt ?? .distantPast,isKapt:false).scopeKey
        return BuildingComplexReview.key([scope,source.latestNoticeDate ?? source.noticeDate])
    }
    static func merge(_ a: Self, _ b: Self) throws -> Self {
        try a.validate(); try b.validate(references:false)
        var prices = Dictionary(a.sources.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        for incoming in b.sources {
            var source = incoming
            if let old = prices[source.id] {
                let newest = max(old.latestNoticeDate ?? old.noticeDate,source.latestNoticeDate ?? source.noticeDate)
                if (old.detailAt ?? .distantPast) > (source.detailAt ?? .distantPast) { source = old }
                if newest > source.noticeDate { source.latestNoticeDate = newest }
            }
            prices[source.id] = source
        }
        var searches = Dictionary(a.searches.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        for search in b.searches where searches[search.id].map({ $0.fetchedAt <= search.fetchedAt }) ?? true { searches[search.id] = search }
        var reviews = Dictionary(a.reviews.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        for review in b.reviews { reviews[review.id] = try reviews[review.id].map { try KaptLinkReview.merge($0,review) } ?? review }
        var observations = Dictionary((a.observations ?? []).map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        for observation in b.observations ?? [] where observations[observation.id].map({ $0.fetchedAt <= observation.fetchedAt }) ?? true { observations[observation.id] = observation }
        let result = Self(searches:searches.values.sorted { $0.id < $1.id },sources:prices.values.sorted { $0.id < $1.id },reviews:reviews.values.sorted { $0.id < $1.id },observations:observations.values.sorted { $0.id < $1.id })
        try result.validate(); return result
    }
}
// Build once per saved checkpoint, off the UI thread during collection.
struct KaptPrimaryIndex {
    var records: [String:KaptReferenceRecord]
    var prices: [String:HousingSource]
    var reviews: [String:KaptLinkReview]
    var searches: [String:KaptPriceSearch]
    var observations: [String:KaptRegistryObservation]
    var detailedIDs: Set<String>
    var decisions: [String:KaptLinkDecision]
    var roads: [String:[String]]
    var provinces: [String] = []
    var districts: [String:[String]] = [:]
    var regions: [String:[String]]
    var populationToken = ""
    var memberOwners: [String:Set<String>] = [:]
    var priceOwners: [String:Set<String>] = [:]
    var managementOwners: [String:Set<String>] = [:]
    init(_ archive: BuildingReferenceArchive) {
        let concordance = archive.concordance ?? KaptConcordance()
        records = Dictionary(archive.records.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        prices = Dictionary(concordance.sources.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        reviews = Dictionary(concordance.reviews.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        searches = Dictionary(concordance.searches.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        observations = Dictionary((concordance.observations ?? []).map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        detailedIDs = Set(concordance.sources.filter { $0.detailAt != nil && ($0.latestNoticeDate == nil || $0.latestNoticeDate == $0.noticeDate) }.map(\.id))
        let priceScopes = Dictionary(concordance.sources.map { ($0.id,KaptConcordance.sourceKey($0)) },uniquingKeysWith:{ x,_ in x })
        let priceFacts = Dictionary(concordance.sources.map { ($0.id,BuildingComplexReview.key($0.fields)) },uniquingKeysWith:{ x,_ in x })
        let knownBuildings = Dictionary((concordance.observations ?? []).flatMap(\.buildings).map { ($0.roadKey + "|" + $0.id,$0) },uniquingKeysWith:{ x,_ in x })
        var sourceScopes: [String:String] = [:], provinceSet = Set<String>(), districtSets: [String:Set<String>] = [:]
        roads = [:]; regions = [:]; decisions = [:]
        for record in archive.records {
            let scope = record.source.scopeKey; sourceScopes[record.id] = scope
            roads[record.id] = record.roads
            for road in record.roads {
                let words = (BuildingAddress.key(road) ?? "").split(separator:" ")
                guard let province = words.first.map(String.init) else { continue }
                let district = words.dropFirst().dropLast(2).joined(separator:" ")
                provinceSet.insert(province); districtSets[province,default:[]].insert(district)
                regions[record.id,default:[]].append(province + "|" + district)
            }
            guard let decision = reviews[record.id]?.decision, !record.hasConfirmedBlankRoad,
                  decision.kaptScopeKey == scope,
                  decision.realtyIDs.allSatisfy({ detailedIDs.contains($0) && decision.realtyScopeKeys[$0] == priceScopes[$0] }) else { continue }
            decisions[record.id] = decision
            if decision.disposition == .accepted, let match = BuildingComplexReview.managementMatchKey(name:record.name,parcel:record.fields["jibunAddress",default:""],fields:record.fields) {
                managementOwners[match,default:[]].insert(record.id)
            }
        }
        for record in archive.records where !record.hasConfirmedBlankRoad {
            for decision in reviews[record.id]?.heads ?? [] where decision.disposition == .accepted {
                for identity in decision.memberBuildings.keys { memberOwners[identity,default:[]].insert(record.id) }
                for id in decision.realtyIDs { priceOwners[id,default:[]].insert(record.id) }
            }
        }
        provinces = provinceSet.sorted(); districts = districtSets.mapValues { $0.filter { !$0.isEmpty }.sorted() }
        let values = archive.records.sorted { $0.id < $1.id }.map { record -> String in
            let decision = decisions[record.id]
            let state = record.hasConfirmedBlankRoad || decision?.disposition == .excluded ? "excluded" : "included"
            let edges = decision.map { BuildingComplexReview.key([$0.realtyScopeKeys,$0.memberBuildings]) } ?? "pending"
            let whole = decision.map { $0.wholeRealtyIDs.sorted().joined(separator:"|") } ?? ""
            let priceData = decision.map { $0.realtyIDs.sorted().compactMap { priceFacts[$0] }.joined(separator:"|") } ?? ""
            let standard = decision?.standardBuildingIdentity ?? ""
            let currentBuilding = knownBuildings[standard].map { BuildingComplexReview.key([$0.complexScopeKey,BuildingComplexReview.key($0.fields)]) } ?? "unconfirmed"
            return BuildingComplexReview.key([record.id,sourceScopes[record.id] ?? "",state,edges,whole,standard,currentBuilding,priceData,
                BuildingComplexReview.key(record.fields),reviews[record.id]?.conflicted == true ? "conflict" : "clear"])
        }
        populationToken = DeviceShareCodec.digest(Data(values.joined(separator:"\n").utf8))
    }
}
extension KaptReferenceRecord {
    var basicFootprint: String { BuildingComplexReview.key([id,name,roads.joined(separator:"\n"),fields["jibunAddress",default:""],fields["approvalDate",default:""],fields["households",default:""],fields["buildings",default:""]]) }
    var roads: [String] { Array(Set(roadAddresses.flatMap(BuildingAddress.split))).sorted() }
    var hasConfirmedBlankRoad: Bool { fetchedAt != nil && roadAddresses.allSatisfy(BuildingFacts.blank) }
    var source: BuildingComplexSource {
        BuildingComplexSource(id:id,name:name,roadAddresses:roads,jibunAddress:fields["jibunAddress",default:""],fields:fields,fetchedAt:facilitiesAt ?? fetchedAt ?? .distantPast,isKapt:true)
    }
}
