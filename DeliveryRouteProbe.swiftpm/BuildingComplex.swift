import Foundation

// A registry summary and a K-apt management area are separate identities.
// A road address is only a search key; it never proves common ownership/use.
struct RegistryBuildingComplex: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var jibunAddress: String
    var roadAddress: String
    var fields: [String:String]
}

struct BuildingComplexSource: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var roadAddresses: [String]
    var jibunAddress: String
    var fields: [String:String]
    var fetchedAt: Date
    var isKapt: Bool
    var scopeKey: String {
        BuildingComplexReview.key([id,name,jibunAddress,roadAddresses.sorted().joined(separator:"\n"),
            fields["approvalDate",default:""],fields["buildings",default:""],fields["households",default:""],fields["registrationStatus",default:""],fields["dongNames",default:""]])
    }
}

struct BuildingComplexDecision: Codable, Equatable, Identifiable {
    var id: String
    var groupForKapt: [String:String]
    var adoptedForGroup: [String:String]
    var groupForBuilding: [String:String]
    var groupForRealty: [String:String]
    var reason: String
    var excludedKaptReasons: [String:String]? = nil
    var wholeScopeGroups: [String]? = nil
    var wholeRealtyIDs: [String]? = nil
}

struct ManagedBuildingComplex: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kaptIDs: [String]
    var adoptedKaptID: String
    var sharedFacts: [String:BuildingFact]
    var reason: String
    var reviewedAt: Date
}

struct BuildingComplexBinding: Codable, Equatable {
    var complexID: String
    var buildingScopeKey: String
    var registryParentID: String?
    var reviewID: String
}

struct BuildingComplexReview: Codable, Equatable, Identifiable {
    var roadAddress: String
    var buildings: [EvaluationBuilding]
    var registryGroups: [RegistryBuildingComplex]
    var candidates: [BuildingComplexSource]
    var realty: [BuildingComplexSource]
    var decision: BuildingComplexDecision
    var confirmed = false
    var automatic = false
    var updatedAt: Date
    var supersedes: [String] = []
    var conflicts: [BuildingComplexDecision] = []
    var comparisonComplete: Bool? = nil
    var id: String { BuildingAddress.key(roadAddress) ?? "" }
    var roots: [String] { Set(decision.groupForKapt.values).sorted() }
    var usable: Bool { confirmed && conflicts.isEmpty && comparisonComplete != false }
    var excludedKaptIDs: Set<String> { Set((decision.excludedKaptReasons ?? [:]).keys) }
    static let sharedKeys: Set<String> = ["parking","parkingGround","parkingUnderground","parkingPerHousehold",
        "chargerGround","chargerUnderground","chargerGroundCount","chargerUndergroundCount","chargerPresent","managementOffice"]
    static func key<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value).base64EncodedString()) ?? ""
    }
    static func nameKey(_ value: String) -> String {
        var value = BuildingAddress.clean(value).lowercased().replacingOccurrences(of:" ",with:"")
        if value.hasSuffix("아파트") { value.removeLast(3) }
        return value
    }
    static func parcelKey(_ value: String) -> String {
        var value = BuildingAddress.clean(value).components(separatedBy:"(")[0].replacingOccurrences(of:"번지",with:"")
        let aliases = ["서울":"서울특별시","대전":"대전광역시","부산":"부산광역시","대구":"대구광역시","인천":"인천광역시","광주":"광주광역시","울산":"울산광역시","세종":"세종특별자치시","경기":"경기도","강원":"강원특별자치도","강원도":"강원특별자치도","충북":"충청북도","충남":"충청남도","전북":"전북특별자치도","전라북도":"전북특별자치도","전남":"전라남도","경북":"경상북도","경남":"경상남도","제주":"제주특별자치도"]
        var words = value.split(separator:" ").map(String.init)
        if let first = words.first, let alias = aliases[first] { words[0] = alias }
        value = words.joined(separator:" ")
        return value
    }
    // All five checks are required. Similar names, totals or a newer download
    // alone do not prove that a management area is the whole registry group.
    static func matches(_ source: BuildingComplexSource, _ group: RegistryBuildingComplex) -> Bool {
        let name = nameKey(source.name), parcel = parcelKey(source.jibunAddress)
        guard !name.isEmpty, name == nameKey(group.name), !parcel.isEmpty, parcel == parcelKey(group.jibunAddress) else { return false }
        for field in ["buildings","households"] {
            guard let a = Int(source.fields[field,default:""]), let b = Int(group.fields[field,default:""]), a > 0, a == b else { return false }
        }
        let date = source.fields["approvalDate",default:""].filter(\.isNumber)
        return date.count == 8 && date == group.fields["approvalDate",default:""].filter(\.isNumber)
    }
    var scopeKey: String {
        Self.key([id] + candidates.sorted { $0.id < $1.id }.map(\.scopeKey)
            + realty.sorted { $0.id < $1.id }.map(\.scopeKey)
            + buildings.sorted { $0.id < $1.id }.map(\.complexScopeKey)
            + registryGroups.sorted { $0.id < $1.id }.map { Self.key([$0.id,$0.name,$0.jibunAddress,$0.fields["approvalDate",default:""],$0.fields["buildings",default:""],$0.fields["households",default:""]]) })
    }
    var decisionKey: String {
        Self.key([decision.groupForKapt,decision.adoptedForGroup,decision.groupForBuilding,decision.groupForRealty,decision.excludedKaptReasons ?? [:],
            Dictionary((decision.wholeScopeGroups ?? []).map { ($0,"whole") },uniquingKeysWith:{ a,_ in a }),
            Dictionary((decision.wholeRealtyIDs ?? []).map { ($0,"whole") },uniquingKeysWith:{ a,_ in a })])
    }
    func validate() throws {
        guard !id.isEmpty, buildings.count <= 5_000, registryGroups.count <= 1_000, candidates.count <= 1_000, realty.count <= 1_000,
              Set(buildings.map(\.id)).count == buildings.count, Set(registryGroups.map(\.id)).count == registryGroups.count,
              Set(candidates.map(\.id)).count == candidates.count, Set(realty.map(\.id)).count == realty.count,
              candidates.allSatisfy(\.isKapt), realty.allSatisfy({ !$0.isKapt }),
              supersedes.count <= 500, conflicts.count <= 20, updatedAt.timeIntervalSince1970.isFinite,
              decision.reason.utf8.count <= 10_000, !decision.id.isEmpty else { throw BuildingEvaluationError.message("단지 판별 기록의 식별자·범위를 확인하세요.") }
        guard (decision.excludedKaptReasons ?? [:]).count <= 1_000, (decision.excludedKaptReasons ?? [:]).values.allSatisfy({ !BuildingFacts.blank($0) && $0.utf8.count <= 5_000 }),
              (decision.wholeScopeGroups ?? []).count <= 1_000, (decision.wholeRealtyIDs ?? []).count <= 1_000,
              Set(decision.wholeRealtyIDs ?? []).isSubset(of:Set(realty.map(\.id))), excludedKaptIDs.isSubset(of:Set(candidates.map(\.id))) else { throw BuildingEvaluationError.message("과거·범위 밖 등록을 제외한 근거를 확인하세요.") }
        for building in buildings { try building.validate(); guard building.roadKey == id else { throw BuildingEvaluationError.message("다른 주소의 건물을 단지 판별에 포함하지 않았습니다.") } }
        for source in candidates + realty {
            guard !source.id.isEmpty, source.id.utf8.count <= 200, source.name.utf8.count <= 500, source.jibunAddress.utf8.count <= 2_000,
                  source.roadAddresses.count <= 100, source.roadAddresses.allSatisfy({ $0.utf8.count <= 2_000 }),
                  source.fields.count <= 100, source.fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) else { throw BuildingEvaluationError.message("단지 비교 원본의 크기를 확인하세요.") }
        }
        for group in registryGroups {
            guard !group.id.isEmpty, group.id.utf8.count <= 200, group.name.utf8.count <= 500, group.jibunAddress.utf8.count <= 2_000,
                  group.roadAddress.utf8.count <= 2_000, group.fields.count <= 100, group.fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) else { throw BuildingEvaluationError.message("총괄표제부 원본을 확인하세요.") }
        }
        guard Set(decision.groupForKapt.keys).isSubset(of:Set(candidates.map(\.id))),
              Set(decision.groupForBuilding.keys).isSubset(of:Set(buildings.map(\.id))),
              Set(decision.groupForRealty.keys).isSubset(of:Set(realty.map(\.id))),
              decision.groupForKapt.count <= 1_000, decision.adoptedForGroup.count <= 1_000,
              decision.groupForBuilding.count <= 5_000, decision.groupForRealty.count <= 1_000 else { throw BuildingEvaluationError.message("단지 판별에 없는 원본·건물을 연결하지 않았습니다.") }
        if confirmed { try validateConfirmed() }
    }
    func validateConfirmed() throws {
        guard comparisonComplete != false else { throw BuildingEvaluationError.message("연결된 도로명주소의 단지 목록 비교가 미완료입니다. 먼저 모든 연결 주소를 조회하세요.") }
        guard !candidates.isEmpty, !BuildingFacts.blank(decision.reason),
              Set(decision.groupForKapt.keys).isDisjoint(with:excludedKaptIDs),
              Set(decision.groupForKapt.keys).union(excludedKaptIDs) == Set(candidates.map(\.id)) else { throw BuildingEvaluationError.message("모든 K-apt 등록의 중복·별개·과거 여부와 판별 근거를 확인하세요.") }
        let rootSet = Set(roots)
        guard Set(decision.adoptedForGroup.keys) == rootSet,
              decision.groupForBuilding.values.allSatisfy({ rootSet.contains($0) }),
              decision.groupForRealty.values.allSatisfy({ rootSet.contains($0) }) else { throw BuildingEvaluationError.message("현황에 채택할 등록과 건물·공시가격의 소속 단지를 확인하세요.") }
        for root in roots {
            guard decision.groupForKapt[root] == root, let adopted = decision.adoptedForGroup[root], decision.groupForKapt[adopted] == root else {
                throw BuildingEvaluationError.message("중복 등록의 대표 단지와 채택할 원본을 확인하세요.")
            }
            let sources = candidates.filter { decision.groupForKapt[$0.id] == root }
            guard Set(decision.wholeScopeGroups ?? []).contains(root), let selected = sources.first(where:{ $0.id == adopted }) else {
                throw BuildingEvaluationError.message("채택한 원본이 관리단지 전체 범위인지 확인하세요. 주소별 부분 등록의 수치를 전체 수치로 사용하지 않습니다.")
            }
            let allRoads = Set(sources.flatMap(\.roadAddresses).compactMap(BuildingAddress.key))
            let adoptedRoads = Set(selected.roadAddresses.compactMap(BuildingAddress.key))
            guard allRoads.isSubset(of:adoptedRoads) else { throw BuildingEvaluationError.message("채택한 원본의 주소 범위가 같은 단지의 모든 주소를 포함하지 않습니다. 전체 주소가 포함된 등록을 채택하세요.") }
            if sources.contains(where:{ $0.fields["registrationStatus"] == "사용" }), selected.fields["registrationStatus"] != "사용" {
                throw BuildingEvaluationError.message("같은 단지에 사용 중인 등록이 있어 중지된 등록을 현황으로 채택하지 않았습니다.")
            }
        }
    }
    static func draft(roadAddress: String, buildings: [EvaluationBuilding], groups: [RegistryBuildingComplex],
                      candidates: [BuildingComplexSource], realty: [BuildingComplexSource], previous: Self? = nil, now: Date = Date()) throws -> Self {
        var result = Self(roadAddress:roadAddress,buildings:buildings,registryGroups:groups,candidates:candidates,realty:realty,
            decision:BuildingComplexDecision(id:UUID().uuidString,groupForKapt:[:],adoptedForGroup:[:],groupForBuilding:[:],groupForRealty:[:],reason:""),updatedAt:now)
        for source in candidates { result.decision.groupForKapt[source.id] = source.id; result.decision.adoptedForGroup[source.id] = source.id }
        if let previous, previous.usable, previous.scopeKey == result.scopeKey {
            result.decision = previous.decision; result.confirmed = true; result.automatic = previous.automatic
            result.supersedes = previous.supersedes; try result.validate(); return result
        }
        var owner: [String:String] = [:], resolved = !candidates.isEmpty
        let matches = Dictionary(candidates.map { source in (source.id,groups.filter { Self.matches(source,$0) }.map(\.id)) },uniquingKeysWith:{ a,_ in a })
        for group in groups {
            let sources = candidates.filter { matches[$0.id] == [group.id] }
            guard !sources.isEmpty else { continue }
            let active = sources.filter { $0.fields["registrationStatus"] == "사용" }
            // Two active registrations with the same summary remain a review
            // question: equal totals do not prove they are duplicate management.
            guard active.count == 1, sources.allSatisfy({ $0.id == active[0].id || $0.fields["registrationStatus"] == "중지" }) else { resolved = false; continue }
            let root = sources.map(\.id).sorted()[0]
            for source in sources { result.decision.groupForKapt[source.id] = root; result.decision.adoptedForGroup.removeValue(forKey:source.id) }
            result.decision.adoptedForGroup[root] = active[0].id; owner[group.id] = root
            result.decision.wholeScopeGroups = (result.decision.wholeScopeGroups ?? []) + [root]
        }
        for candidate in candidates {
            if matches[candidate.id]?.count != 1 || owner[matches[candidate.id]?.first ?? ""] == nil { resolved = false }
        }
        for building in buildings { if let parent = building.parentRegistryID, let root = owner[parent] { result.decision.groupForBuilding[building.id] = root } }
        for source in realty {
            let exact = candidates.filter { candidate in
                result.decision.adoptedForGroup[result.decision.groupForKapt[candidate.id,default:""]] == candidate.id &&
                Self.nameKey(source.name) == Self.nameKey(candidate.name) && !Self.nameKey(source.name).isEmpty &&
                Self.parcelKey(source.jibunAddress) == Self.parcelKey(candidate.jibunAddress) && !Self.parcelKey(source.jibunAddress).isEmpty &&
                ["buildings","households"].allSatisfy { Int(source.fields[$0,default:""]) != nil && source.fields[$0] == candidate.fields[$0] } &&
                source.fields["approvalDate",default:""].filter(\.isNumber).count == 8 && source.fields["approvalDate",default:""].filter(\.isNumber) == candidate.fields["approvalDate",default:""].filter(\.isNumber)
            }
            if exact.count == 1 {
                result.decision.groupForRealty[source.id] = result.decision.groupForKapt[exact[0].id]
                if Set(exact[0].roadAddresses.compactMap(BuildingAddress.key)).isSubset(of:Set(source.roadAddresses.compactMap(BuildingAddress.key))) {
                    result.decision.wholeRealtyIDs = (result.decision.wholeRealtyIDs ?? []) + [source.id]
                }
            }
        }
        result.confirmed = resolved; result.automatic = resolved
        result.decision.reason = resolved ? "총괄표제부의 단지명·지번·사용승인일·동수·세대수 일치 및 K-apt 사용/중지 상태로 판별" : ""
        if result.confirmed, (try? result.validateConfirmed()) == nil { result.confirmed = false; result.automatic = false; result.decision.reason = "" }
        if let previous { result.supersedes = Array(Set(previous.supersedes + [previous.decision.id] + previous.conflicts.map(\.id))).sorted() }
        if let previous, !previous.conflicts.isEmpty { result.conflicts = previous.conflicts; result.confirmed = false; result.automatic = false }
        try result.validate(); return result
    }
    func reusingManagementDecision(_ reviews: [Self]) -> Self {
        guard !usable, conflicts.isEmpty, comparisonComplete != false else { return self }
        let candidatesKey = candidates.sorted { $0.id < $1.id }.map(\.scopeKey)
        let groupKey = registryGroups.sorted { $0.id < $1.id }.map { Self.key([$0.id,$0.name,$0.jibunAddress,$0.fields["approvalDate",default:""],$0.fields["households",default:""],$0.fields["buildings",default:""]]) }
        guard let prior = reviews.filter({ review in
            review.usable && review.candidates.sorted { $0.id < $1.id }.map(\.scopeKey) == candidatesKey &&
            review.registryGroups.sorted { $0.id < $1.id }.map { Self.key([$0.id,$0.name,$0.jibunAddress,$0.fields["approvalDate",default:""],$0.fields["households",default:""],$0.fields["buildings",default:""]]) } == groupKey
        }).max(by:{ $0.updatedAt < $1.updatedAt }) else { return self }
        var result = self
        result.decision.groupForKapt = prior.decision.groupForKapt; result.decision.adoptedForGroup = prior.decision.adoptedForGroup
        result.decision.excludedKaptReasons = prior.decision.excludedKaptReasons; result.decision.wholeScopeGroups = prior.decision.wholeScopeGroups
        result.decision.reason = prior.decision.reason; result.decision.groupForBuilding = [:]; result.decision.groupForRealty = [:]
        result.decision.wholeRealtyIDs = []
        for building in buildings {
            if let old = prior.buildings.first(where:{ $0.id == building.id }), old.complexScopeKey == building.complexScopeKey {
                result.decision.groupForBuilding[building.id] = prior.decision.groupForBuilding[building.id]
                continue
            }
            let matching = candidates.filter { candidate in
                let root = result.decision.groupForKapt[candidate.id,default:""]
                guard result.decision.adoptedForGroup[root] == candidate.id, let parent = building.parentRegistryID,
                      let group = registryGroups.first(where:{ $0.id == parent }) else { return false }
                return Self.matches(candidate,group)
            }
            if matching.count == 1 { result.decision.groupForBuilding[building.id] = result.decision.groupForKapt[matching[0].id] }
        }
        for source in realty {
            if let old = prior.realty.first(where:{ $0.id == source.id }), old.scopeKey == source.scopeKey {
                result.decision.groupForRealty[source.id] = prior.decision.groupForRealty[source.id]
                if (prior.decision.wholeRealtyIDs ?? []).contains(source.id) { result.decision.wholeRealtyIDs?.append(source.id) }
            }
        }
        result.confirmed = true; result.automatic = prior.automatic
        do { try result.validate(); return result } catch { return self }
    }
    mutating func normalizeGroups() throws {
        let original = decision.groupForKapt
        for source in candidates where !excludedKaptIDs.contains(source.id) {
            var root = source.id, seen = Set<String>()
            while let next = original[root], next != root {
                guard seen.insert(root).inserted else { throw BuildingEvaluationError.message("중복 단지 선택이 서로 순환합니다. 대표 등록 하나를 선택하세요.") }; root = next
            }
            guard original[root] == root else { throw BuildingEvaluationError.message("대표 등록을 확인하세요.") }
            decision.groupForKapt[source.id] = root
        }
        decision.adoptedForGroup = decision.adoptedForGroup.filter { roots.contains($0.key) && decision.groupForKapt[$0.value] == $0.key }
        for root in roots where decision.adoptedForGroup[root] == nil {
            let sources = candidates.filter { decision.groupForKapt[$0.id] == root }
            let active = sources.filter { $0.fields["registrationStatus"] == "사용" }
            decision.adoptedForGroup[root] = active.count == 1 ? active[0].id : root
        }
        decision.groupForBuilding = decision.groupForBuilding.filter { roots.contains($0.value) }
        decision.groupForRealty = decision.groupForRealty.filter { roots.contains($0.value) }
        decision.wholeScopeGroups = (decision.wholeScopeGroups ?? []).filter { roots.contains($0) }
    }
    func individualFacts(_ building: EvaluationBuilding) -> [String:BuildingFact] {
        let root = usable ? decision.groupForBuilding[building.id] : nil
        let price = Self.consensus(realty.filter { source in
            guard root != nil, decision.groupForRealty[source.id] == root else { return false }
            if (decision.wholeRealtyIDs ?? []).contains(source.id) { return true }
            let labels = source.fields["dongNames",default:""].components(separatedBy:CharacterSet(charactersIn:",;\n，")).map(BuildingAddress.dongKey).filter { !$0.isEmpty }
            let dong = BuildingAddress.dongKey(building.dongName)
            return !dong.isEmpty && labels.contains(dong) && buildings.filter { decision.groupForBuilding[$0.id] == root && BuildingAddress.dongKey($0.dongName) == dong }.count == 1
        }.map(\.fields))
        let kapt = candidates.first { $0.id == root.flatMap { decision.adoptedForGroup[$0] } }?.fields ?? [:]
        let supplemental = BuildingFacts.resolve(registry:building.fields,realty:price,kapt:kapt,apartment:building.fields["use",default:""].contains("아파트") || root != nil)
        var result = supplemental.filter { $0.value.scope == .building || !Self.sharedKeys.contains($0.key) }
        if let root { for key in result.keys where result[key]?.scope == .complex { result[key]?.complexID = "kapt:" + root } }
        return result
    }
    static func consensus(_ values: [[String:String]]) -> [String:String] { BuildingFacts.consensus(values) }
    func complex(_ root: String) -> ManagedBuildingComplex? {
        guard usable, let code = decision.adoptedForGroup[root], let adopted = candidates.first(where:{ $0.id == code }) else { return nil }
        let complexID = "kapt:" + root
        var registry: [String:String] = [:]
        let exact = registryGroups.filter { Self.matches(adopted,$0) }
        if exact.count == 1 {
            let parent = exact[0].id
            let competing = Set(candidates.filter { Self.matches($0,exact[0]) }.compactMap { decision.groupForKapt[$0.id] })
            let assigned = Set(buildings.filter { $0.parentRegistryID == parent }.compactMap { decision.groupForBuilding[$0.id] })
            if competing == [root] && assigned == [root] { registry = exact[0].fields }
        }
        let price = Self.consensus(realty.filter { decision.groupForRealty[$0.id] == root && (decision.wholeRealtyIDs ?? []).contains($0.id) }.map(\.fields))
        var facts: [String:BuildingFact] = [:]
        for (source,fields) in [(BuildingFactSource.registry,registry),(.realty,price),(.kapt,adopted.fields)] {
            for (field,value) in fields where facts[field] == nil && !BuildingFacts.blank(value) && (Self.sharedKeys.contains(field) || ["households","buildings"].contains(field)) {
                let key = field == "households" ? "complexHouseholds" : field == "buildings" ? "complexBuildings" : field
                if facts[key] == nil { facts[key] = BuildingFact(value:value,source:source,scope:.complex,complexID:complexID) }
            }
        }
        // The denominator is the management area's households, never this dong.
        if let parking = Double(facts["parking"]?.value ?? ""), let households = Double(facts["complexHouseholds"]?.value ?? ""), parking.isFinite, households.isFinite, parking >= 0, households > 0 {
            facts["parkingPerHousehold"] = BuildingFact(value:String(format:"%.4f",parking/households),source:facts["parking"]!.source,scope:.complex,complexID:complexID)
        }
        return ManagedBuildingComplex(id:complexID,name:adopted.name,kaptIDs:candidates.filter { decision.groupForKapt[$0.id] == root }.map(\.id).sorted(),
            adoptedKaptID:code,sharedFacts:facts,reason:decision.reason,reviewedAt:updatedAt)
    }
    func binding(_ building: EvaluationBuilding) -> BuildingComplexBinding? {
        guard usable, let original = buildings.first(where:{ $0.id == building.id }), original.complexScopeKey == building.complexScopeKey,
              let root = decision.groupForBuilding[building.id] else { return nil }
        return BuildingComplexBinding(complexID:"kapt:" + root,buildingScopeKey:building.complexScopeKey,registryParentID:building.parentRegistryID,reviewID:decision.id)
    }
    static func merge(_ a: Self, _ b: Self) throws -> Self {
        try a.validate(); try b.validate(); guard a.id == b.id else { throw BuildingEvaluationError.message("다른 주소의 단지 판별 기록입니다.") }
        if a.decision.id == b.decision.id { return b.updatedAt >= a.updatedAt ? b : a }
        if b.supersedes.contains(a.decision.id) && a.conflicts.allSatisfy({ b.supersedes.contains($0.id) }) { return b }
        if a.supersedes.contains(b.decision.id) && b.conflicts.allSatisfy({ a.supersedes.contains($0.id) }) { return a }
        if a.usable && b.usable && a.scopeKey == b.scopeKey && a.decisionKey == b.decisionKey { return b.updatedAt >= a.updatedAt ? b : a }
        var result = b.updatedAt >= a.updatedAt ? b : a
        if a.confirmed || b.confirmed || !a.conflicts.isEmpty || !b.conflicts.isEmpty {
            result.confirmed = false; result.automatic = false
            result.conflicts = Dictionary((a.conflicts + b.conflicts + [a.decision,b.decision]).map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x }).values.sorted { $0.id < $1.id }
            result.decision.reason = "두 기기의 판별이 달라 공용 정보를 보류했습니다. 비교 후 다시 확정하세요."
        }
        try result.validate(); return result
    }
    // Cross-address contradictions also block sharing; a K-apt code cannot
    // silently become two independent management identities on two devices.
    static func sharedComplexes(_ reviews: [Self]) -> [String:ManagedBuildingComplex] {
        var aliases: [String:Set<String>] = [:], infos: [String:[ManagedBuildingComplex]] = [:], blocked = Set<String>()
        for review in reviews {
            if !review.usable {
                for source in review.candidates { blocked.insert(source.id) }
                continue
            }
            blocked.formUnion(review.excludedKaptIDs)
            for (code,root) in review.decision.groupForKapt { aliases[code,default:[]].insert(root) }
            for root in review.roots { if let info = review.complex(root) { infos[root,default:[]].append(info) } }
        }
        var result: [String:ManagedBuildingComplex] = [:]
        for (root,values) in infos {
            let allIDs = Set(values.flatMap(\.kaptIDs))
            guard allIDs.isDisjoint(with:blocked), allIDs.allSatisfy({ aliases[$0]?.count == 1 }), Set(values.map(\.adoptedKaptID)).count == 1 else { continue }
            if let value = values.max(by:{ $0.reviewedAt < $1.reviewedAt }) { result[value.id] = value }
        }
        return result
    }
    static func excludedCodes(_ reviews: [Self]) -> Set<String> {
        var uses: [String:Set<Bool>] = [:]
        for review in reviews {
            for source in review.candidates { uses[source.id,default:[]].insert(review.usable && review.excludedKaptIDs.contains(source.id)) }
        }
        return Set(uses.filter { $0.value == [true] }.keys)
    }
}

extension EvaluationBuilding {
    var complexScopeKey: String { BuildingComplexReview.key([id,roadKey,name,dongName,parentRegistryID ?? "",parcelID ?? ""]) }
}
