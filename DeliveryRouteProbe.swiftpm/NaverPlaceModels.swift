import Foundation
import JavaScriptCore

struct NaverPlaceCapture: Codable, Identifiable {
    var id: String {
        guard isSharedAddress, let point = coordinate else { return selectionKey }
        return selectionKey + ":\(Int64((point.longitude * 10_000_000).rounded())):\(Int64((point.latitude * 10_000_000).rounded()))"
    }
    var version: Int
    var kind: String
    var selectionKey: String
    var placeID: String
    var name: String
    var address: String
    var roadAddress: String
    var jibunAddress: String
    var sourceURL: String
    var coordinate: TMapCoordinate?
    var point: MapRoutePoint?
    var tileZoom: Int?
    var screenResolutionMeters: Double?
    var coordinateIssue: String
    var capturedAt: String
    var method: String
    var requestAddress: String?
    var geocodeProvider: String?
    var geocodedAddress: String?
    var apiEvidence: NaverAPIEvidence?
    var sharedLinkURL: String?
    var preferredAddress: String { !roadAddress.isEmpty ? roadAddress : address }
    var isSharedAddress: Bool { kind == "address" && sharedLinkURL != nil }
    func matchesSelection(_ other: NaverPlaceCapture?) -> Bool {
        guard let other, selectionKey == other.selectionKey else { return false }
        guard isSharedAddress || other.isSharedAddress else { return true }
        guard let first = coordinate, let second = other.coordinate else { return false }
        return (first.longitude * 10_000_000).rounded() == (second.longitude * 10_000_000).rounded()
            && (first.latitude * 10_000_000).rounded() == (second.latitude * 10_000_000).rounded()
    }
}

struct NaverAPIEvidence: Codable {
    var provider: String
    var name: String
    var roadAddress: String
    var jibunAddress: String
    var x: String
    var y: String
}

struct NaverPlaceAttachment: Decodable {
    var plan: DeliveryPlan
    var stopID: String
    var invalidated: Int
    var coordinateChanged: Bool
}
private struct NaverPlaceEnvelope<T: Decodable>: Decodable {
    var ok: Bool
    var value: T?
    var message: String?
}
struct NaverPlaceSelectionCheck: Decodable { var same: Bool }

enum NaverPlaceBridge {
    static func call<T: Decodable>(_ method: String, _ input: [String: Any], as type: T.Type) throws -> T {
        guard let context = JSContext() else { throw PlannerFailure.message("네이버 장소 처리기를 열지 못했습니다.") }
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        context.evaluateScript(NaverPlaceEngineSource.source)
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "네이버 장소 처리 오류") }
        let value = context.objectForKeyedSubscript("DeliveryNaverPlaces")?.invokeMethod(method + "JSON", withArguments: [String(decoding: data, as: UTF8.self)])
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "네이버 장소 처리 오류") }
        guard let text = value?.toString(), let output = text.data(using: .utf8) else { throw PlannerFailure.message("네이버 장소 결과를 읽지 못했습니다.") }
        let envelope = try JSONDecoder().decode(NaverPlaceEnvelope<T>.self, from: output)
        guard envelope.ok, let result = envelope.value else { throw PlannerFailure.message(envelope.message ?? "네이버 장소 연결 실패") }
        return result
    }
}

extension DeliveryPlan {
    func naverPlace(_ id: String) -> NaverPlaceCapture? {
        id == "depot" ? naverOrigin : id == "destination" ? destination?.naverPlace : visits.first(where: { $0.id == id })?.naverPlace
    }
}
