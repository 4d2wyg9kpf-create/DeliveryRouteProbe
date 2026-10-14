import Foundation
private func require(_ value: Bool, _ message: String) throws { if !value { throw BuildingEvaluationError.message(message) } }
private func rejects(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw BuildingEvaluationError.message("expected rejection") }
@main struct BuildingComplexChecks {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ action: () throws -> Void) throws { try action(); passed += 1; print("PASS \(name)") }
        let date = Date(timeIntervalSince1970:1791950000)
        let road = "대전광역시 서구 가상로 10", road2 = "대전광역시 서구 가상로 20"
        func group(_ id: String, _ name: String, _ count: String, _ parking: String) -> RegistryBuildingComplex {
            RegistryBuildingComplex(id:id,name:name,jibunAddress:"대전광역시 서구 가상동 1",roadAddress:road,
                fields:["buildings":"2","households":count,"approvalDate":"2020-12-01","parking":parking])
        }
        let g1 = group("G1","새봄1아파트","100","1000"), g2 = group("G2","새봄2아파트","200","3000")
        func building(_ id: String, _ dong: String, _ parent: String?, _ address: String? = nil) -> EvaluationBuilding {
            EvaluationBuilding(id:id,roadAddress:address ?? road,name:parent == "G2" ? "새봄2아파트" : "새봄1아파트",dongName:dong,
                fields:["use":"아파트","parking":"0","households":"50"],fetchedAt:date,parentRegistryID:parent,parcelID:"parcel")
        }
        let b1 = building("B101","101동","G1"), b2 = building("B102","102동","G1"), b3 = building("B201","201동","G2")
        func profile(_ id: String, _ group: RegistryBuildingComplex, _ status: String = "사용", _ roads: [String]? = nil, _ parking: String = "1200") -> BuildingComplexSource {
            var fields = group.fields; fields["registrationStatus"] = status; fields["parking"] = parking; fields["heating"] = "지역난방"
            return BuildingComplexSource(id:id,name:group.name,roadAddresses:roads ?? [road],jibunAddress:group.jibunAddress,fields:fields,fetchedAt:date,isKapt:true)
        }
        let k1 = profile("K1",g1), old = profile("OLD",g1,"중지"), k2 = profile("K2",g2,"사용",nil,"2400")
        func draft(_ profiles: [BuildingComplexSource], _ buildings: [EvaluationBuilding] = [b1,b2], _ groups: [RegistryBuildingComplex] = [g1], _ prices: [BuildingComplexSource] = []) throws -> BuildingComplexReview {
            try BuildingComplexReview.draft(roadAddress:road,buildings:buildings,groups:groups,candidates:profiles,realty:prices,now:date)
        }
        let duplicate = try draft([k1,old])
        try check("active and suspended identical registry coverage adopt the active record") {
            try require(duplicate.usable && duplicate.roots.count == 1 && duplicate.decision.adoptedForGroup[duplicate.roots[0]] == "K1","active adoption")
        }
        try check("duplicate parking is not added and registry group wins") {
            try require(duplicate.complex(duplicate.roots[0])?.sharedFacts["parking"]?.value == "1000","duplicate sum")
        }
        try check("building parking and shared parking retain distinct scopes") {
            try require(duplicate.individualFacts(b1)["parking"]?.value == "0" && duplicate.complex(duplicate.roots[0])?.sharedFacts["parking"]?.scope == .complex,"scope conflation")
        }
        try check("management household denominator differs from this building's households") {
            try require(duplicate.complex(duplicate.roots[0])?.sharedFacts["parkingPerHousehold"]?.value == "10.0000","building denominator")
        }
        let separate = try draft([k1,k2],[b1,b2,b3],[g1,g2])
        try check("same road with two registry summaries maps distinct management areas") {
            try require(separate.usable && separate.decision.groupForBuilding[b1.id] == "K1" && separate.decision.groupForBuilding[b3.id] == "K2","separate membership")
        }
        try check("separate complexes do not add or share parking") {
            try require(separate.complex("K1")?.sharedFacts["parking"]?.value == "1000" && separate.complex("K2")?.sharedFacts["parking"]?.value == "3000","parking crossed management")
        }
        try check("missing upper registry PK never infers membership by address") {
            let noParent = building("NO","103동",nil)
            let result = try draft([k1],[noParent])
            try require(result.binding(noParent) == nil,"address-only membership")
        }
        try check("two active matching records require an explicit duplicate decision") {
            let result = try draft([k1,profile("DUP",g1)])
            try require(!result.usable && result.binding(b1) == nil,"active clones guessed")
        }
        try check("equal totals on two equal summaries do not identify the parent management") {
            var equal = g1; equal.id = "OTHER"
            try require(try !draft([k1],[b1],[g1,equal]).usable,"ambiguous summaries guessed")
        }
        try check("suspended-only or unknown status are not silently current") {
            try require(try !draft([old]).usable && !draft([profile("UNKNOWN",g1,"미확인")]).usable,"status guessed")
        }
        try check("different approval dates are not considered current duplicate coverage") {
            var source = old; source.fields["approvalDate"] = "1985-01-01"
            try require(try !draft([k1,source]).usable,"old development merged")
        }
        try check("names and parcels are required, not just matching counts") {
            var source = k1; source.name = "다른아파트"
            try require(try !draft([source]).usable,"name ignored")
            source = k1; source.jibunAddress = "대전광역시 서구 가상동 2"
            try require(try !draft([source]).usable,"parcel ignored")
        }
        try check("one parent summary can contain two explicitly separate management areas") {
            var result = try draft([k1,profile("SPLIT",g1,"사용",nil,"2400")])
            result.decision.groupForBuilding = [b1.id:"K1",b2.id:"SPLIT"]
            result.decision.wholeScopeGroups = ["K1","SPLIT"]; result.decision.reason = "관리 범위가 서로 별개임을 확인"; result.confirmed = true
            try result.validate()
            try require(result.complex("K1")?.sharedFacts["parking"]?.value == "1200" && result.complex("SPLIT")?.sharedFacts["parking"]?.value == "2400","parent totals leaked into split areas")
        }
        var full = profile("NEW",g1,"사용",[road,road2])
        var a = profile("PARTA",g1,"사용",[road],"600"); a.fields["buildings"] = "1"; a.fields["households"] = "50"
        var b = profile("PARTB",g1,"사용",[road2],"600"); b.fields["buildings"] = "1"; b.fields["households"] = "50"
        var past = profile("PAST",g1,"사용",[road]); past.name = "재건축전단지"; past.fields["approvalDate"] = "1985-01-01"; past.fields["households"] = "80"
        var reconstruction = try draft([past,full,a,b])
        reconstruction.decision.groupForKapt = ["NEW":"NEW","PARTA":"NEW","PARTB":"NEW"]
        reconstruction.decision.adoptedForGroup = ["NEW":"NEW"]; reconstruction.decision.groupForBuilding = [b1.id:"NEW",b2.id:"NEW"]
        reconstruction.decision.excludedKaptReasons = ["PAST":"재건축 전 등록의 멸실을 대장과 비교해 확인"]
        reconstruction.decision.wholeScopeGroups = ["NEW"]; reconstruction.decision.reason = "현재 두 건물번호 전체 원본과 주소별 중복 등록을 대장과 비교"; reconstruction.confirmed = true
        try check("reconstruction plus whole and two partial registrations retain one current management") {
            try reconstruction.validate()
            try require(reconstruction.roots == ["NEW"] && reconstruction.excludedKaptIDs == ["PAST"] && reconstruction.complex("NEW")?.kaptIDs == ["NEW","PARTA","PARTB"],"four registrations unresolved")
        }
        try check("whole and partial registrations never sum shared counts") {
            try require(reconstruction.complex("NEW")?.sharedFacts["parking"]?.value == "1000","whole plus partial sum")
        }
        try check("partial-address registration cannot be adopted as whole management") {
            var wrong = reconstruction; wrong.decision.adoptedForGroup["NEW"] = "PARTA"
            try rejects { try wrong.validate() }
        }
        try check("excluding a historical record requires a recorded reason") {
            var wrong = reconstruction; wrong.decision.excludedKaptReasons = ["PAST":""]
            try rejects { try wrong.validate() }
        }
        try check("unconfirmed exclusion cannot remove an address from the population") {
            var wrong = reconstruction; wrong.confirmed = false
            try require(BuildingComplexReview.excludedCodes([wrong]).isEmpty,"unconfirmed exclusion applied")
        }
        try check("explicit historical exclusion is preserved without deleting the source") {
            try require(BuildingComplexReview.excludedCodes([reconstruction]) == ["PAST"] && reconstruction.candidates.count == 4,"raw historical registration lost")
        }
        try check("active registration must be adopted over a suspended duplicate") {
            var wrong = duplicate; wrong.decision.adoptedForGroup[wrong.roots[0]] = "OLD"
            try rejects { try wrong.validate() }
        }
        try check("whole-scope confirmation is required for shared totals") {
            var wrong = reconstruction; wrong.decision.wholeScopeGroups = []
            try rejects { try wrong.validate() }
        }
        let otherBuilding = building("B103","103동","G1",road2)
        let otherDraft = try BuildingComplexReview.draft(roadAddress:road2,buildings:[otherBuilding],groups:[g1],candidates:[past,full,a,b],realty:[],now:date.addingTimeInterval(1))
        let otherReview = otherDraft.reusingManagementDecision([reconstruction])
        try check("confirmed whole management classification is reused across its two addresses") {
            try require(otherReview.usable && otherReview.binding(otherBuilding)?.complexID == "kapt:NEW","multi-address management split")
        }
        try check("same management shares one current common record across addresses") {
            let shared = BuildingComplexReview.sharedComplexes([reconstruction,otherReview])
            try require(shared.count == 1 && shared["kapt:NEW"]?.sharedFacts["parking"]?.value == "1000","cross-address duplicate parking")
        }
        try check("membership is invalidated when upper registry or dong changes") {
            var changed = b1; changed.parentRegistryID = "NEWPARENT"
            try require(reconstruction.binding(changed) == nil,"changed parent reused")
            changed = b1; changed.dongName = "501동"; try require(reconstruction.binding(changed) == nil,"changed dong reused")
        }
        try check("inconsistent management aliases across addresses block sharing") {
            var inconsistent = otherReview
            inconsistent.decision.groupForKapt = ["NEW":"PARTA","PARTA":"PARTA","PARTB":"PARTA"]
            inconsistent.decision.adoptedForGroup = ["PARTA":"NEW"]; inconsistent.decision.groupForBuilding = [otherBuilding.id:"PARTA"]; inconsistent.decision.wholeScopeGroups = ["PARTA"]
            try inconsistent.validate()
            try require(BuildingComplexReview.sharedComplexes([reconstruction,inconsistent]).isEmpty,"inconsistent aliases silently shared")
        }
        try check("two device membership decisions preserve both alternatives and withhold facts") {
            var other = reconstruction; other.decision.id = "other-device"; other.decision.groupForBuilding = [b1.id:"NEW"]
            let merged = try BuildingComplexReview.merge(reconstruction,other)
            try require(!merged.usable && merged.conflicts.count == 2 && BuildingComplexReview.sharedComplexes([merged]).isEmpty,"device conflict overwritten")
        }
        try check("explicit conflict resolution supersedes both alternative decisions") {
            var other = reconstruction; other.decision.id = "other-device"; other.decision.groupForBuilding = [b1.id:"NEW"]
            let conflict = try BuildingComplexReview.merge(reconstruction,other)
            var fixed = reconstruction; fixed.decision.id = "resolved"; fixed.supersedes = conflict.conflicts.map(\.id) + [conflict.decision.id]
            try require(try BuildingComplexReview.merge(conflict,fixed).usable,"resolved decision blocked")
        }
        try check("automatic reload cannot erase an unresolved device conflict") {
            var alternative = duplicate; alternative.decision.id = "different"; alternative.decision.groupForBuilding = [:]
            let conflict = try BuildingComplexReview.merge(duplicate,alternative)
            let reload = try BuildingComplexReview.draft(roadAddress:road,buildings:[b1,b2],groups:[g1],candidates:[k1,old],realty:[],previous:conflict,now:date.addingTimeInterval(1))
            try require(!reload.usable && reload.conflicts.count == 2,"conflict silently auto-resolved")
        }
        var noParking = g1; noParking.fields["parking"] = ""
        var current = try draft([k1],[b1,b2],[noParking])
        try check("fresh shared values can update without changing a verified management scope") {
            var changed = k1; changed.fields["parking"] = "1300"; changed.fetchedAt = date.addingTimeInterval(100)
            current = try BuildingComplexReview.draft(roadAddress:road,buildings:[b1,b2],groups:[noParking],candidates:[changed],realty:[],previous:current,now:date.addingTimeInterval(100))
            try require(current.usable && current.complex("K1")?.sharedFacts["parking"]?.value == "1300","fresh shared value failed")
        }
        var partialPrice = k1; partialPrice.id = "price-part"; partialPrice.isKapt = false; partialPrice.fields["parking"] = "500"; partialPrice.fields["households"] = "50"; partialPrice.fields["buildings"] = "1"; partialPrice.fields["dongNames"] = "101동"; partialPrice.fields["heating"] = "개별난방"
        var priceReview = try draft([k1],[b1,b2],[noParking],[partialPrice])
        priceReview.decision.groupForRealty = [partialPrice.id:"K1"]; priceReview.decision.reason = "101동 공시가격 소속을 확인"; priceReview.confirmed = true
        try check("partially scoped price parking cannot replace whole management parking") {
            try priceReview.validate(); try require(priceReview.complex("K1")?.sharedFacts["parking"]?.value == "1200","partial price total applied")
        }
        try check("price dong information supplements only the matched building in its management") {
            try require(priceReview.individualFacts(b1)["heating"]?.value == "개별난방" && priceReview.individualFacts(b2)["heating"]?.value == "지역난방","price facts crossed dongs")
        }
        try check("management-adopted source never falls back to another duplicate's blanks") {
            var onlyOld = old; onlyOld.fields["waterSupply"] = "중력식"
            var result = try draft([k1,onlyOld]); result.decision.reason = "원본 확인"
            try require(result.individualFacts(b1)["waterSupply"] == nil,"old duplicate fills current blanks")
        }
        try check("review persistence retains all raw sources, exclusions, membership and adoption") {
            let data = try JSONEncoder().encode(reconstruction)
            let restored = try JSONDecoder().decode(BuildingComplexReview.self,from:data)
            try restored.validate(); try require(restored == reconstruction,"review persistence")
        }
        var activeTwin = k1; activeTwin.id = "TWIN"; activeTwin.roadAddresses = [road,road2]; activeTwin.fields["parking"] = "2400"
        var activeOriginal = k1; activeOriginal.roadAddresses = [road,road2]
        var initialChoice = try draft([activeOriginal,activeTwin],[b1,b2],[noParking])
        initialChoice.decision.groupForKapt = ["K1":"K1","TWIN":"K1"]; initialChoice.decision.adoptedForGroup = ["K1":"K1"]
        initialChoice.decision.wholeScopeGroups = ["K1"]; initialChoice.decision.groupForBuilding = [b1.id:"K1",b2.id:"K1"]
        initialChoice.decision.reason = "관리 단지 전체 범위를 비교하여 채택"; initialChoice.confirmed = true
        let secondChoice = try BuildingComplexReview.draft(roadAddress:road2,buildings:[otherBuilding],groups:[noParking],candidates:[activeOriginal,activeTwin],realty:[],now:date.addingTimeInterval(1)).reusingManagementDecision([initialChoice])
        var updatedChoice = initialChoice; updatedChoice.decision.id = "updated-adoption"; updatedChoice.decision.adoptedForGroup["K1"] = "TWIN"
        updatedChoice.updatedAt = date.addingTimeInterval(10); updatedChoice.dataCheckedAt = updatedChoice.updatedAt
        try updatedChoice.validate()
        try check("changing adopted duplicate propagates across its confirmed road addresses") {
            let propagated = secondChoice.updatingAdoption(from:updatedChoice)
            try require(propagated?.decision.adoptedForGroup["K1"] == "TWIN" && propagated?.binding(otherBuilding)?.complexID == "kapt:K1","adoption propagation lost members")
            let infos = BuildingComplexReview.sharedComplexes([updatedChoice,propagated!])
            try require(infos["kapt:K1"]?.adoptedKaptID == "TWIN" && infos["kapt:K1"]?.sharedFacts["parking"]?.value == "2400","common adoption not refreshed")
        }
        try check("adoption propagation never silently changes a different management partition") {
            var incompatible = secondChoice; incompatible.decision.groupForKapt["TWIN"] = "TWIN"; incompatible.decision.adoptedForGroup["TWIN"] = "TWIN"; incompatible.decision.wholeScopeGroups = ["K1","TWIN"]
            try incompatible.validate(); try require(incompatible.updatingAdoption(from:updatedChoice) == nil,"different partition overwritten")
        }
        try check("incomplete linked-address inventory cannot be manually confirmed") {
            var incomplete = reconstruction; incomplete.confirmed = false; incomplete.comparisonComplete = false
            try rejects { incomplete.confirmed = true; try incomplete.validate() }
        }
        try check("older building records decode without parent or management evidence") {
            let data = Data("{\"id\":\"legacy\",\"roadAddress\":\"대전광역시 서구 가상로 10\",\"name\":\"이전 건물\",\"dongName\":\"101동\",\"fields\":{},\"fetchedAt\":0}".utf8)
            let oldBuilding = try JSONDecoder().decode(EvaluationBuilding.self,from:data)
            try require(oldBuilding.parentRegistryID == nil && oldBuilding.parcelID == nil,"old archive failed")
        }
        print("Building complex checks: \(passed)/\(passed) passed")
    }
}
