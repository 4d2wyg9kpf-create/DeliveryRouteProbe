import Foundation

private func require(_ value: Bool, _ message: String) throws { if !value { throw BuildingEvaluationError.message(message) } }
private func rejects(_ work: () throws -> Void) throws { do { try work() } catch { return }; throw BuildingEvaluationError.message("expected rejection") }
@main struct BuildingEvaluationChecks {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ work: () throws -> Void) throws { try work(); passed += 1; print("PASS \(name)") }
        let date = Date(timeIntervalSince1970:1791882000), road = "대전광역시 중구 가상로 10"
        func building(_ id: String, _ dong: String, _ address: String? = nil) -> EvaluationBuilding {
            EvaluationBuilding(id:id,roadAddress:address ?? road,name:"가상 건물",dongName:dong,fields:["use":"공동주택 · 아파트"],fetchedAt:date)
        }
        let first = building("b101","101동"), second = building("b102","102동")
        try check("one address one building chooses its building") {
            let result = try BuildingSelector.choose([first],roadAddress:road)
            try require(result.0.id == first.id && result.1 == .single,"single building")
        }
        try check("multiple buildings default to first dong regardless of response order") {
            let result = try BuildingSelector.choose([second,first],roadAddress:road)
            try require(result.0.id == first.id && result.1 == .firstDong,"first dong")
        }
        try check("dong sorting is numeric and does not choose ten before two") {
            try require(try BuildingSelector.choose([building("ten","10동"),building("two","2동")],roadAddress:road).0.id == "two","natural number order")
        }
        try check("named dongs use a fixed Korean locale and stable ordering") {
            try require(try BuildingSelector.choose([building("b","나동"),building("a","가동")],roadAddress:road).0.id == "a","named order")
        }
        try check("specified dong overrides first dong") {
            let result = try BuildingSelector.choose([first,second],roadAddress:road,dong:"102")
            try require(result.0.id == second.id && result.1 == .specifiedDong,"specified override")
        }
        try check("missing specified dong never silently falls back") { try rejects { _ = try BuildingSelector.choose([first,second],roadAddress:road,dong:"103동") } }
        try check("blank dong among multiple buildings keeps default unresolved") { try rejects { _ = try BuildingSelector.choose([first,building("blank","")],roadAddress:road) } }
        try check("duplicate normalized dong labels are not guessed") { try rejects { _ = try BuildingSelector.choose([first,building("duplicate","0101동")],roadAddress:road) } }
        try check("same parcel but another road address is excluded") {
            try require(try BuildingSelector.choose([first,building("other","1동","대전광역시 중구 가상로 20")],roadAddress:road).0.id == first.id,"other road")
        }
        try check("missing registered dongs blocks default choice") { try rejects { _ = try BuildingSelector.choose([second],roadAddress:road,expectedDongNames:["101동","102동"]) } }
        try check("explicit building can be selected while another dong is unresolved") {
            try require(try BuildingSelector.choose([second],roadAddress:road,dong:"102동",expectedDongNames:["101동","102동"]).1 == .specifiedDong,"explicit known building")
        }
        try check("coordinate source and entrance proof are required") {
            var selection = BuildingSelection(building:first,choice:.firstDong,entranceSource:"가상 확인",entranceID:"fixture-entrance",longitude:127.4,latitude:36.3)
            try selection.validate(); selection.entranceSource = ""; try rejects { try selection.validate() }
            selection.entranceSource = "가상 확인"; selection.longitude = 0; try rejects { try selection.validate() }
        }
        try check("two dongs at one road address have separate identities") {
            let a = BuildingSelection(building:first,choice:.firstDong,entranceSource:"가상 확인",entranceID:"a",longitude:127.4,latitude:36.3)
            let b = BuildingSelection(building:second,choice:.specifiedDong,entranceSource:"가상 확인",entranceID:"b",longitude:127.41,latitude:36.3)
            try require(a.identity != b.identity && a.isDefaultForAddress && !b.isDefaultForAddress,"building identities")
        }
        try check("explicit first dong may still be the default reference building") {
            let value = BuildingSelection(building:first,choice:.specifiedDong,entranceSource:"가상 확인",entranceID:"a",longitude:127.4,latitude:36.3,defaultForAddress:true)
            try require(value.isDefaultForAddress,"explicit first designation")
        }
        try check("registry populated values always override both supplements") {
            let values = BuildingFacts.resolve(registry:["households":"10","approvalDate":"2020-01-01"],realty:["households":"100"],kapt:["households":"200"],apartment:true)
            try require(values["households"]?.value == "10" && values["households"]?.source == .registry,"registry overridden")
        }
        try check("realty precedes Kapt only for missing registry fields") {
            let values = BuildingFacts.resolve(registry:["households":""],realty:["households":"100"],kapt:["households":"200","heating":"지역난방"],apartment:true)
            try require(values["households"]?.source == .realty && values["heating"]?.source == .kapt,"fallback order")
        }
        try check("aggregate complex figures retain their scope") {
            let values = BuildingFacts.resolve(registry:[:],realty:["households":"100"],kapt:[:],apartment:true)
            try require(values["households"]?.scope == .complex,"aggregate mislabelled per building")
        }
        try check("zero is real data and is never overwritten as missing") {
            let values = BuildingFacts.resolve(registry:["parking":"0"],realty:["parking":"100"],kapt:[:],apartment:true)
            try require(values["parking"]?.value == "0" && values["parking"]?.source == .registry,"zero overwritten")
        }
        try check("nonapartment buildings are not filled with an apartment complex") {
            try require(BuildingFacts.resolve(registry:[:],realty:["parking":"100"],kapt:["households":"200"],apartment:false).isEmpty,"wrong scope applied")
        }
        try check("conflicting duplicate registrations never invent a count") {
            try require(BuildingFacts.consensus([["households":"100"],["households":"200"]])["households"] == nil,"conflicting records chosen")
        }
        try check("same repeated and blank facts retain one supported value") {
            try require(BuildingFacts.consensus([["heating":"지역난방"],["heating":""],["heating":"지역난방"]])["heating"] == "지역난방","consensus")
        }
        try check("road aliases units and zero padding canonicalize for address dedupe") {
            try require(BuildingAddress.key("대전 중구 가상로 010 101동 303호") == BuildingAddress.key(road),"canonical road")
            try require(BuildingAddress.key("대전 중구 가상로 10-01") == BuildingAddress.key("대전광역시 중구 가상로 10-1"),"sub number")
        }
        try check("building number difference is preserved") { try require(BuildingAddress.key(road) != BuildingAddress.key("대전광역시 중구 가상로 11"),"address collapsed") }
        try check("parenthesized locality comma is not a second address") { try require(BuildingAddress.split(road + " (가상동, 가상아파트)").count == 1,"parenthesis split") }
        let other = "대전광역시 중구 가상길 20"
        try check("all unique addresses of a multiple-address complex are included") {
            let result = try KaptReferenceCatalog.build([KaptReferenceRecord(id:"A1",name:"가상단지",roadAddresses:[road + "; " + other],fetchedAt:date)])
            try require(result.addresses.count == 2 && result.complete,"multi address lost")
        }
        try check("road duplicate is represented once and original Kapt IDs survive") {
            let records = [KaptReferenceRecord(id:"A1",name:"가상1",roadAddresses:[road],fetchedAt:date),KaptReferenceRecord(id:"A2",name:"가상2",roadAddresses:["대전 중구 가상로 10"],fetchedAt:date)]
            let result = try KaptReferenceCatalog.build(records)
            try require(result.addresses.count == 1 && result.duplicateAddressCount == 1 && result.addresses[0].kaptIDs == ["A1","A2"],"duplicate source lost")
        }
        try check("confirmed blank road addresses are excluded without deleting source") {
            let result = try KaptReferenceCatalog.build([KaptReferenceRecord(id:"blank",name:"가상공란",roadAddresses:[""],fetchedAt:date)])
            try require(result.addresses.isEmpty && result.missingAddressIDs == ["blank"] && result.complete,"blank rule")
        }
        try check("detail not collected is unresolved not classified as demolished") {
            let result = try KaptReferenceCatalog.build([KaptReferenceRecord(id:"pending",name:"가상미수집",roadAddresses:[])])
            try require(result.missingAddressIDs.isEmpty && result.unresolvedIDs == ["pending"] && !result.complete,"unfetched excluded")
        }
        try check("partially malformed multiaddress stays unresolved") {
            let result = try KaptReferenceCatalog.build([KaptReferenceRecord(id:"partial",name:"가상형식",roadAddresses:[road + "; 잘못된주소"],fetchedAt:date)])
            try require(result.addresses.isEmpty && result.unresolvedIDs == ["partial"],"partial address accepted")
        }
        try check("two roads without a delimiter are not silently truncated") {
            let result = try KaptReferenceCatalog.build([KaptReferenceRecord(id:"partial",name:"가상형식",roadAddresses:[road + " " + other],fetchedAt:date)])
            try require(!result.complete && result.addresses.isEmpty,"truncated second address")
        }
        try check("duplicate raw Kapt codes are rejected") { try rejects { _ = try KaptReferenceCatalog.build([KaptReferenceRecord(id:"same",name:"가상1",roadAddresses:[]),KaptReferenceRecord(id:"same",name:"가상2",roadAddresses:[])]) } }
        try check("serialization preserves building identity entrance source and fact scope") {
            let selection = BuildingSelection(building:first,choice:.firstDong,entranceSource:"가상 출입구자료",entranceID:"a",longitude:127.4,latitude:36.3)
            let data = try JSONEncoder().encode(selection), restored = try JSONDecoder().decode(BuildingSelection.self,from:data)
            try require(restored == selection,"serialization changed building")
        }
        try check("reference catalog supports a nationwide population above old 5000 limit") {
            let records = (1...6000).map { KaptReferenceRecord(id:"A\($0)",name:"가상표준\($0)",roadAddresses:["대전광역시 중구 가상로 \($0)"],fetchedAt:date) }
            try require(try KaptReferenceCatalog.build(records).addresses.count == 6000,"nationwide truncation")
        }
        print("Building evaluation checks: \(passed)/\(passed) passed")
    }
}
