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
            try require(pinCustomers.records.count == 1 && pinSites.records.count == 1 && pinCustomers.records[0].capture?.coordinate?.longitude == 127.4000002 && pinSites.records[0].capture.coordinate?.longitude == 127.4000002, "address duplicate added or incoming pin coordinate lost")
        }
        try check("reimporting the same point updates its existing identity") {
            let customerID = pinCustomers.records[0].id, siteID = pinSites.records[0].id
            let addedCustomer = try pinCustomers.save(pinA), addedSite = try pinSites.save(pinA)
            try require(!addedCustomer && !addedSite && pinCustomers.records[0].id == customerID && pinSites.records[0].id == siteID, "same point duplicated")
        }
        try check("new short URL for the same point does not create a duplicate") {
            let repeated = try sharedPoint(127.4, url: "https://naver.me/pointAgain")
            let added = try pinCustomers.save(repeated)
            try require(!added && pinCustomers.records.count == 1 && pinCustomers.records[0].capture?.sharedLinkURL == repeated.sharedLinkURL, "regenerated URL split the same point")
        }
        try check("shared-point coordinates and identities survive file recreation") {
            let restoredCustomers = NaverCustomerStore(directory: pinFolder), restoredSites = SiteTargetStore(directory: pinFolder)
            try require(restoredCustomers.errorMessage == nil && restoredSites.errorMessage == nil && restoredCustomers.records.count == 1 && restoredSites.records.count == 1, "shared point archive corrupt")
            try require(restoredCustomers.records[0].capture?.coordinate?.longitude == 127.4 && restoredSites.records[0].capture.coordinate?.longitude == 127.4000002, "selected coordinate lost")
        }
        try check("remembering selected deliveries keeps the updated address record and original identity") {
            var plan = DeliveryPlan(); plan.visits = pinCustomers.records.map(\.template)
            try pinCustomers.remember(plan)
            try require(pinCustomers.records.count == 1 && pinCustomers.records[0].capture?.coordinate?.longitude == 127.4, "plan migration changed the updated record")
        }
        try check("shared address without selected coordinates cannot enter either list") {
            var missing = pinA; missing.coordinate = nil; missing.point = nil; missing.method = "rendered_selected_address_panel"
            for destination in NaverImportDestination.allCases {
                do { _ = try NaverImportSink.save(missing, destination: destination, customers: pinCustomers, sites: pinSites); throw PlannerFailure.message("missing point saved") }
                catch { try require(pinCustomers.records.count == 1 && pinSites.records.count == 1, "missing point modified a list") }
            }
        }
        print("Place destination native checks: \(passed)/\(passed) passed")
    }
}
