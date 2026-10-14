import Foundation
import JavaScriptCore

// Type-only legacy planner dependencies; both shipped destination stores and
// the real NAVER validation engine are compiled below without UI or network.
struct TMapCoordinate: Codable, Equatable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
struct MapRoutePoint: Codable { var token: String; var name: String }
struct Access: Codable { var curbConfirmed = false }
struct DeliveryVisit: Codable {
    var id = UUID().uuidString; var name = ""; var naverPlace: NaverPlaceCapture?
    var tmapCoordinate: TMapCoordinate?; var roadAccess: Access?
}
struct Destination: Codable { var customerID: String; var naverPlace: NaverPlaceCapture? }
struct DeliveryPlan: Codable {
    var visits: [DeliveryVisit] = []; var naverOrigin: NaverPlaceCapture?; var tmapOrigin: TMapCoordinate?
    var originName = "가상 출발지"; var originAccess: Access?; var originCustomerID: String?; var destination: Destination?
}
@MainActor final class PlannerStore {
    var plan = DeliveryPlan(); var autoSaveEnabled = true; var isComputing = false; var errorMessage: String?; var message = ""
    func saveNow() {}
}
enum PlannerFailure: LocalizedError { case message(String); var errorDescription: String? { if case .message(let message) = self { return message }; return nil } }
enum TMapBridge {
    static func object<T: Encodable>(_ input: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) }
    static func coordinate(_ plan: DeliveryPlan, id: String) -> TMapCoordinate? { id == "depot" ? plan.tmapOrigin : plan.visits.first { $0.id == id }?.tmapCoordinate }
}
private func require(_ value: Bool, _ message: String) throws { if !value { throw PlannerFailure.message(message) } }
private func capture(_ number: Int) throws -> NaverPlaceCapture {
    let context = JSContext()!
    context.evaluateScript(NaverPlaceEngineSource.source); context.evaluateScript(NaverAPIEngineSource.source)
    let input: [String: Any] = ["response": ["items": [["title": "가상 장소 \(number)", "roadAddress": "대전광역시 중구 가상로 \(number)",
        "address": "대전광역시 중구 가상동 \(number)", "mapx": "1274000000", "mapy": "363000000", "category": "가상업종"]]], "now": 1_791_602_000_000, "provider": "hub"]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
    let result = context.objectForKeyedSubscript("DeliveryNaverAPI")!.invokeMethod("localJSON", withArguments: [json])!.toString()!
    struct Result: Decodable { struct Row: Decodable { var capture: NaverPlaceCapture }; var ok: Bool; var value: [Row]? }
    let parsed = try JSONDecoder().decode(Result.self, from: Data(result.utf8))
    try require(parsed.ok && parsed.value?.count == 1, "fixture capture")
    return parsed.value![0].capture
}
private func sharedPoint(_ longitude: Double, url: String) throws -> NaverPlaceCapture {
    var value = try capture(101)
    value.method = "rendered_selected_marker_and_tiles"; value.geocodeProvider = nil; value.apiEvidence = nil
    value.coordinate = TMapCoordinate(longitude: longitude, latitude: 36.3)
    value.tileZoom = 18; value.screenResolutionMeters = 1
    let x = longitude / 180 * 20037508.342789244, y = 6378137 * log(tan(Double.pi / 4 + 36.3 * Double.pi / 360))
    let name = value.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    value.point = MapRoutePoint(token: "\(x),\(y),\(name),,SIMPLE_POI", name: value.name)
    return try NaverPlaceBridge.call("shared", ["capture": try TMapBridge.object(value), "url": url], as: NaverPlaceCapture.self)
}
private func sharedBusiness(_ longitude: String = "127.4000001") throws -> NaverPlaceCapture {
    var parts = URLComponents(string: "https://map.naver.com/")!
    parts.queryItems = [URLQueryItem(name: "pinId", value: "101"), URLQueryItem(name: "pinType", value: "site"),
        URLQueryItem(name: "menu", value: "location"), URLQueryItem(name: "title", value: "가상식당 가상점"),
        URLQueryItem(name: "lng", value: longitude), URLQueryItem(name: "lat", value: "36.3000001")]
    return try NaverPlaceBridge.call("sharedPin", ["resolvedURL": parts.url!.absoluteString,
        "sharedURL": "https://naver.me/fixtureSite", "sharedName": "가상식당 가상점", "sharedAddress": "대전 유성구 가상로 11",
        "now": 1_791_602_000_000], as: NaverPlaceCapture.self)
}

@main struct DestinationNativeChecks {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("place-destinations-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let customers = NaverCustomerStore(directory: folder), sites = SiteTargetStore(directory: folder)
        var passed = 0
        func check(_ name: String, _ block: () throws -> Void) throws { try block(); passed += 1; print("PASS \(name)") }
        let first = try capture(1)
        try check("customer destination does not populate evaluation sites") {
            _ = try NaverImportSink.save(first, destination: .customers, customers: customers, sites: sites)
            try require(customers.records.count == 1 && sites.records.isEmpty, "independent destinations")
        }
        try check("site destination does not add a delivery customer") {
            _ = try NaverImportSink.save(try capture(2), destination: .sites, customers: customers, sites: sites)
            try require(customers.records.count == 1 && sites.records.count == 1, "site only")
        }
        try check("same place updates without a duplicate and keeps original identity") {
            let id = sites.records[0].id
            let added = try sites.save(try capture(2), name: "수정한 가상 장소", folder: "가상 폴더")
            try require(!added && sites.records.count == 1 && sites.records[0].id == id && sites.records[0].name == "수정한 가상 장소", "deduplication")
        }
        try check("all folder rows save to chosen site destination with coordinates") {
            for number in 3...27 { _ = try NaverImportSink.save(try capture(number), folder: "가상 공유 목록", destination: .sites, customers: customers, sites: sites) }
            try require(sites.records.count == 26 && customers.records.count == 1, "bulk destination")
            try require(sites.records.allSatisfy { $0.coordinate.latitude == 36.3 && $0.coordinate.longitude == 127.4 }, "coordinates persisted")
        }
        try check("target list survives recreation without affecting customer archive") {
            let restored = SiteTargetStore(directory: folder), customerCopy = NaverCustomerStore(directory: folder)
            try require(restored.errorMessage == nil && restored.records.count == 26 && customerCopy.records.count == 1, "recreation")
        }
        try check("deleting an evaluation site leaves delivery customers intact") {
            try sites.remove(sites.records[0].id)
            try require(sites.records.count == 25 && customers.records.count == 1 && SiteTargetStore(directory: folder).records.count == 25, "delete and persist")
        }
        try check("tampered coordinate proof never enters either destination") {
            var bad = first; bad.coordinate?.longitude = 127.5
            for destination in NaverImportDestination.allCases {
                do { _ = try NaverImportSink.save(bad, destination: destination, customers: customers, sites: sites); throw PlannerFailure.message("tampered place accepted") }
                catch { try require(customers.records.count == 1 && sites.records.count == 25, "no stored corruption") }
            }
        }
        let buildingFolder = folder.appendingPathComponent("building-fixtures")
        let buildingSites = SiteTargetStore(directory:buildingFolder)
        let buildingA = EvaluationBuilding(id:"fixture-registry-101",roadAddress:"대전광역시 중구 가상로 10",name:"가상 아파트",dongName:"101동",fields:["use":"아파트"],fetchedAt:Date())
        var buildingB = buildingA; buildingB.id = "fixture-registry-102"; buildingB.dongName = "102동"
        let entranceA = BuildingSelection(building:buildingA,choice:.firstDong,entranceSource:"가상 확인",entranceID:"fixture-a",longitude:127.4,latitude:36.3)
        let entranceB = BuildingSelection(building:buildingB,choice:.specifiedDong,entranceSource:"가상 확인",entranceID:"fixture-b",longitude:127.4001,latitude:36.3)
        try check("different registry buildings at one address persist as distinct evaluation targets") {
            _ = try buildingSites.saveBuilding(entranceA,facts:[:]); _ = try buildingSites.saveBuilding(entranceB,facts:[:])
            try require(buildingSites.records.count == 2 && SiteTargetStore.sharingKey(buildingSites.records[0]) != SiteTargetStore.sharingKey(buildingSites.records[1]),"building identities collapsed")
        }
        try check("same registry building refresh keeps its evaluation identity") {
            let oldID = buildingSites.records[0].id
            var entrance = entranceA; entrance.longitude = 127.4002
            let newID = try buildingSites.saveBuilding(entrance,facts:["parking":BuildingFact(value:"100",source:.kapt,scope:.complex)])
            try require(oldID == newID && buildingSites.records.count == 2 && buildingSites.records[0].effectiveCoordinate.longitude == 127.4002,"building refresh changed identity")
        }
        try check("registry building entrance and supplemental scope survive recreation") {
            let restored = SiteTargetStore(directory:buildingFolder)
            try require(restored.errorMessage == nil && restored.records.count == 2 && restored.records[0].building?.building.dongName == "101동" && restored.records[0].buildingFacts?["parking"]?.scope == .complex,"building persistence")
        }
        try check("blank entrance evidence cannot create a building evaluation target") {
            var bad = entranceA; bad.entranceSource = ""
            var rejected = false
            do { _ = try buildingSites.saveBuilding(bad,facts:[:]) } catch { rejected = true }
            try require(rejected && buildingSites.records.count == 2,"invalid entrance accepted or altered records")
        }
        try check("corrupt target archive is preserved and not overwritten") {
            let url = folder.appendingPathComponent("site-targets.json"), original = Data("corrupt-fixture".utf8)
            try original.write(to: url)
            let broken = SiteTargetStore(directory: folder)
            do { _ = try broken.save(first); throw PlannerFailure.message("corrupt archive overwritten") } catch {}
            let preserved = try Data(contentsOf: url)
            try require(broken.errorMessage != nil && preserved == original, "preserve bad file")
        }
        let pinFolder = folder.appendingPathComponent("shared-pins", isDirectory: true)
        let pinCustomers = NaverCustomerStore(directory: pinFolder), pinSites = SiteTargetStore(directory: pinFolder)
        let pinA = try sharedPoint(127.4, url: "https://naver.me/pointA"), pinB = try sharedPoint(127.4000002, url: "https://naver.me/pointB")
        try check("different shared points at the same address update one record in both destinations") {
            for pin in [pinA, pinB] { _ = try pinCustomers.save(pin); _ = try pinSites.save(pin) }
            try require(pinCustomers.records.count == 1 && pinSites.records.count == 1 && pinCustomers.records[0].capture?.coordinate?.longitude == 127.4000002 && pinSites.records[0].capture?.coordinate?.longitude == 127.4000002, "address duplicate added or incoming pin coordinate lost")
        }
        try check("reimporting the same point updates its existing identity") {
            let customerID = pinCustomers.records[0].id, siteID = pinSites.records[0].id
            let addedCustomer = try pinCustomers.save(pinB), addedSite = try pinSites.save(pinB)
            try require(!addedCustomer && !addedSite && pinCustomers.records[0].id == customerID && pinSites.records[0].id == siteID, "same point duplicated")
        }
        try check("new short URL for the same point does not create a duplicate") {
            let repeated = try sharedPoint(127.4000002, url: "https://naver.me/pointAgain")
            let added = try pinCustomers.save(repeated)
            try require(!added && pinCustomers.records.count == 1 && pinCustomers.records[0].capture?.sharedLinkURL == repeated.sharedLinkURL, "regenerated URL split the same point")
        }
        try check("shared-point coordinates and identities survive file recreation") {
            let restoredCustomers = NaverCustomerStore(directory: pinFolder), restoredSites = SiteTargetStore(directory: pinFolder)
            try require(restoredCustomers.errorMessage == nil && restoredSites.errorMessage == nil && restoredCustomers.records.count == 1 && restoredSites.records.count == 1, "shared point archive corrupt")
            try require(restoredCustomers.records[0].capture?.coordinate?.longitude == 127.4000002 && restoredSites.records[0].capture?.coordinate?.longitude == 127.4000002, "selected coordinate lost")
        }
        try check("remembering selected deliveries keeps the updated address record and original identity") {
            var plan = DeliveryPlan(); plan.visits = pinCustomers.records.map(\.template)
            try pinCustomers.remember(plan)
            try require(pinCustomers.records.count == 1 && pinCustomers.records[0].capture?.coordinate?.longitude == 127.4000002, "plan migration changed the updated record")
        }
        try check("shared address without selected coordinates cannot enter either list") {
            var missing = pinA; missing.coordinate = nil; missing.point = nil; missing.method = "rendered_selected_address_panel"
            for destination in NaverImportDestination.allCases {
                do { _ = try NaverImportSink.save(missing, destination: destination, customers: pinCustomers, sites: pinSites); throw PlannerFailure.message("missing point saved") }
                catch { try require(pinCustomers.records.count == 1 && pinSites.records.count == 1, "missing point modified a list") }
            }
        }
        try check("shared customer catalog retains selected point and deletion across stale plans") {
            let ca = NaverCustomerStore(directory: folder.appendingPathComponent("sync-a")), cb = NaverCustomerStore(directory: folder.appendingPathComponent("sync-b"))
            _ = try ca.save(pinA); _ = try cb.save(pinB)
            let originalID = ca.records[0].id
            var a = DeviceShareReplica(deviceID: "00000000-0000-0000-0000-000000000001"), b = DeviceShareReplica(deviceID: "00000000-0000-0000-0000-000000000002")
            var oa: [String: Data] = [:], ob: [String: Data] = [:]
            try a.capture(ca.sharingSnapshot(), observed: &oa); try b.capture(cb.sharingSnapshot(), observed: &ob); try a.merge(b)
            try ca.applySharing(a); try cb.applySharing(a)
            try require(ca.records.count == 1 && cb.records.count == 1 && ca.records[0].id == originalID && ca.records[0].capture?.coordinate?.longitude == 127.4000002 && ca.records[0].capture?.sharedLinkURL == pinB.sharedLinkURL, "shared pin or identity changed")
            var stale = DeliveryPlan(); stale.visits = ca.records.map(\.template)
            oa = try ca.sharingSnapshot().values
            try ca.remove(ca.records[0].id); try a.capture(ca.sharingSnapshot(), observed: &oa)
            try cb.applySharing(a); try cb.remember(stale)
            try require(cb.records.isEmpty, "stale delivery plan resurrected a remotely deleted customer")
        }
        let siteFolder = folder.appendingPathComponent("http-sites", isDirectory: true)
        let siteCustomers = NaverCustomerStore(directory: siteFolder), siteTargets = SiteTargetStore(directory: siteFolder)
        try check("HTTP business share saves and reloads exact coordinates, metadata and evidence in both destinations") {
            let pin = try sharedBusiness()
            _ = try siteCustomers.save(pin); _ = try siteTargets.save(pin)
            let customerCopy = NaverCustomerStore(directory: siteFolder), siteCopy = SiteTargetStore(directory: siteFolder)
            try require(customerCopy.errorMessage == nil && siteCopy.errorMessage == nil && customerCopy.records.count == 1 && siteCopy.records.count == 1, "HTTP site archive")
            for saved in [customerCopy.records[0].capture!, siteCopy.records[0].capture!] {
                try require(saved.coordinate?.longitude == 127.4000001 && saved.coordinate?.latitude == 36.3000001 && saved.placeID == "101", "HTTP site coordinate changed")
                try require(saved.address == "대전 유성구 가상로 11" && saved.sharedPinEvidence?.sharedAddress == saved.address && saved.method == "naver_shared_link_coordinate", "HTTP site proof lost")
            }
        }
        try check("new selected point for the same business updates one stored record while preserving identity") {
            let customerID = siteCustomers.records[0].id, siteID = siteTargets.records[0].id
            let updated = try sharedBusiness("127.4000002")
            let customerAdded = try siteCustomers.save(updated), siteAdded = try siteTargets.save(updated)
            try require(!customerAdded && !siteAdded && siteCustomers.records.count == 1 && siteTargets.records.count == 1, "HTTP site duplicated")
            try require(siteCustomers.records[0].id == customerID && siteTargets.records[0].id == siteID, "HTTP site identity changed")
            try require(NaverCustomerStore(directory: siteFolder).records[0].capture?.coordinate?.longitude == 127.4000002 && SiteTargetStore(directory: siteFolder).records[0].capture?.coordinate?.longitude == 127.4000002, "HTTP site new coordinate not persisted")
        }
        try check("manual coordinate edits preserve raw shared proof and survive reload") {
            let original = siteCustomers.records[0].capture!, siteOriginal = siteTargets.records[0].capture!
            let edited = TMapCoordinate(longitude: 127.4009, latitude: 36.3008)
            try siteCustomers.setCoordinate(siteCustomers.records[0].id, coordinate: edited)
            try siteTargets.setCoordinate(siteTargets.records[0].id, coordinate: edited)
            let customer = NaverCustomerStore(directory: siteFolder).records[0], target = SiteTargetStore(directory: siteFolder).records[0]
            try require(customer.effectiveCoordinate?.longitude == edited.longitude && target.effectiveCoordinate.latitude == edited.latitude, "manual edit lost")
            try require(customer.capture?.sharedLinkURL == original.sharedLinkURL && target.capture?.coordinate?.longitude == siteOriginal.coordinate?.longitude, "original proof rewritten")
        }
        try check("manual targets without Naver evidence persist and coordinate restore works") {
            let id = try siteTargets.saveManual(name: "직접 지정 시설", address: "", coordinate: TMapCoordinate(longitude: 127.4, latitude: 36.3))
            try siteTargets.setCoordinate(id, coordinate: TMapCoordinate(longitude: 127.5, latitude: 36.4))
            try siteTargets.setCoordinate(id, coordinate: nil)
            let copy = SiteTargetStore(directory: siteFolder)
            try require(copy.records.first { $0.id == id }?.effectiveCoordinate.longitude == 127.4 && copy.records.first { $0.id == id }?.capture == nil, "manual target lost")
        }
        try check("independently selected same Naver place shares once and preserves local identity") {
            let copy = SiteTargetStore(directory: siteFolder.appendingPathComponent("device-b"))
            _ = try copy.save(try sharedBusiness("127.4000002"))
            let localID = copy.records[0].id
            var replica = DeviceShareReplica(deviceID: UUID().uuidString), observed: [String: Data] = [:]
            try replica.capture(siteTargets.sharingSnapshot(), observed: &observed); try copy.applySharing(replica)
            try require(copy.records.count == 2 && copy.records.first { $0.capture != nil }?.id == localID, "shared site duplicated")
            try require(copy.records.first { $0.capture != nil }?.effectiveCoordinate.longitude == 127.4009, "shared manual edit lost")
        }
        try check("restoring customer coordinates returns to raw capture after template migration") {
            let id = siteCustomers.records[0].id
            var plan = DeliveryPlan(); var visit = siteCustomers.records[0].template
            visit.tmapCoordinate = TMapCoordinate(longitude: 127.4009, latitude: 36.3008); plan.visits = [visit]
            try siteCustomers.remember(plan); try siteCustomers.setCoordinate(id, coordinate: nil)
            try require(siteCustomers.records[0].effectiveCoordinate?.longitude == siteCustomers.records[0].capture?.coordinate?.longitude, "restored customer kept migrated manual position")
        }
        var scopedA = entranceA, scopedB = entranceB
        scopedA.building.parentRegistryID = "scope1"; scopedB.building.parentRegistryID = "scope1"
        var scopedC = scopedB; scopedC.building.id = "scope-building3"; scopedC.building.dongName = "201동"; scopedC.building.parentRegistryID = "scope2"
        let scope1 = RegistryBuildingComplex(id:"scope1",name:"가상 단지1",jibunAddress:"대전광역시 중구 가상동 1",roadAddress:buildingA.roadAddress,fields:["buildings":"2","households":"100","approvalDate":"2020-01-01","parking":""])
        var scope2 = scope1; scope2.id = "scope2"; scope2.name = "가상 단지2"; scope2.fields["households"] = "200"
        let profile1 = BuildingComplexSource(id:"K1",name:scope1.name,roadAddresses:[buildingA.roadAddress],jibunAddress:scope1.jibunAddress,fields:scope1.fields.merging(["registrationStatus":"사용","parking":"1000"]){_,new in new},fetchedAt:Date(),isKapt:true)
        var profile2 = profile1; profile2.id = "K2"; profile2.name = scope2.name; profile2.fields["households"] = "200"; profile2.fields["parking"] = "2000"
        var scopeReview = try BuildingComplexReview.draft(roadAddress:buildingA.roadAddress,buildings:[scopedA.building,scopedB.building,scopedC.building],groups:[scope1,scope2],candidates:[profile1,profile2],realty:[])
        try require(scopeReview.usable,"scope fixture unresolved")
        _ = try buildingSites.saveBuilding(scopedA,facts:[:]); _ = try buildingSites.saveBuilding(scopedB,facts:[:]); _ = try buildingSites.saveBuilding(scopedC,facts:[:])
        try check("same management buildings share parking and separate management remains independent") {
            try buildingSites.applyComplexReviews([scopeReview])
            let a = buildingSites.records.first { $0.building?.building.id == scopedA.building.id }!, b = buildingSites.records.first { $0.building?.building.id == scopedB.building.id }!, c = buildingSites.records.first { $0.building?.building.id == scopedC.building.id }!
            try require(a.managedComplex?.sharedFacts["parking"]?.value == "1000" && b.managedComplex?.id == a.managedComplex?.id && c.managedComplex?.sharedFacts["parking"]?.value == "2000","management shared across wrong scope")
        }
        try check("refreshed management data updates all saved member buildings together") {
            let coordinates = buildingSites.records.map(\.effectiveCoordinate)
            var fresh = profile1; fresh.fields["parking"] = "1100"
            scopeReview = try BuildingComplexReview.draft(roadAddress:buildingA.roadAddress,buildings:scopeReview.buildings,groups:[scope1,scope2],candidates:[fresh,profile2],realty:[],previous:scopeReview,now:Date().addingTimeInterval(100))
            try buildingSites.applyComplexReviews([scopeReview])
            try require(buildingSites.records.filter { $0.complexBinding?.complexID == "kapt:K1" }.allSatisfy { $0.managedComplex?.sharedFacts["parking"]?.value == "1100" } && buildingSites.records.map(\.effectiveCoordinate) == coordinates,"shared refresh failed or moved entrances")
        }
        try check("membership and common source survive store recreation") {
            let restored = SiteTargetStore(directory:buildingFolder)
            try require(restored.errorMessage == nil && restored.records.filter { $0.complexBinding != nil }.count == 3 && restored.records.first?.managedComplex?.sharedFacts["parking"]?.complexID == "kapt:K1","complex persistence")
        }
        try check("changed upper registry invalidates prior shared parking until reviewed") {
            var moved = scopedB; moved.building.parentRegistryID = "scope2"
            _ = try buildingSites.saveBuilding(moved,facts:[:]); try buildingSites.applyComplexReviews([scopeReview])
            try require(buildingSites.records.first { $0.building?.building.id == moved.building.id }?.managedComplex == nil,"changed membership reused")
        }
        try check("conflicted decisions remove outdated common values from every affected member") {
            var other = scopeReview; other.decision.id = "other-device"; other.decision.groupForBuilding[scopedA.building.id] = "K2"
            let conflict = try BuildingComplexReview.merge(scopeReview,other)
            try buildingSites.applyComplexReviews([conflict])
            try require(buildingSites.records.allSatisfy { $0.managedComplex == nil && $0.complexBinding == nil },"conflicting common facts retained")
        }
        try check("confirming another default building retains records and one address default") {
            var other = scopedC; other.defaultForAddress = true
            _ = try buildingSites.saveBuilding(other,facts:[:])
            try require(buildingSites.records.count == 3 && buildingSites.records.filter { $0.building?.isDefaultForAddress == true }.count == 1,"default change erased building or duplicated default")
        }
        print("Place destination native checks: \(passed)/\(passed) passed")
    }
}
