import Foundation
import JavaScriptCore

struct TMapCoordinate: Codable, Equatable {
    var longitude: Double
    var latitude: Double
    var poiID: String?
    var detailAddress: String?
}

struct TMapPlanBinding: Codable {
    var visitIDs: [String]
    var legIDs: [String]
    var capturedAt: String
    var expiresAt: String
}

struct TMapOptions: Codable {
    var searchOption = "2"
    var deliveryAccuracy = "1"
    var truckRouting = true
    var truckWidth = 0
    var truckHeight = 0
    var truckWeight = 0
    var truckTotalWeight = 0
    var truckLength = 0
    init() {}
    private enum CodingKeys: String, CodingKey {
        case searchOption, deliveryAccuracy, truckRouting, truckWidth, truckHeight, truckWeight, truckTotalWeight, truckLength
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        searchOption = try values.decodeIfPresent(String.self, forKey: .searchOption) ?? "2"
        deliveryAccuracy = try values.decodeIfPresent(String.self, forKey: .deliveryAccuracy) ?? "1"
        truckRouting = try values.decodeIfPresent(Bool.self, forKey: .truckRouting) ?? true
        truckWidth = try values.decodeIfPresent(Int.self, forKey: .truckWidth) ?? 0
        truckHeight = try values.decodeIfPresent(Int.self, forKey: .truckHeight) ?? 0
        truckWeight = try values.decodeIfPresent(Int.self, forKey: .truckWeight) ?? 0
        truckTotalWeight = try values.decodeIfPresent(Int.self, forKey: .truckTotalWeight) ?? 0
        truckLength = try values.decodeIfPresent(Int.self, forKey: .truckLength) ?? 0
    }
}

struct TMapProviderLeg: Codable {
    var requestFrom: TMapCoordinate
    var requestTo: TMapCoordinate
    var travelSeconds: Int
    var distanceMeters: Double
    var tollWon: Double?
    var requestedCarType: String
    var geometry: [TMapCoordinate]
}

struct TMapQuotaBucket: Codable { var used: Int; var serverBlocked: Bool }
struct TMapQuotaAccount: Codable {
    var period: String
    var lastTrustedMs: Double
    var buckets: [String: TMapQuotaBucket]
}
struct TMapQuotaLedger: Codable {
    var version = 1
    var accounts: [String: TMapQuotaAccount] = [:]
}
struct TMapQuota: Decodable, Identifiable {
    var id: Int
    var label: String
    var limit: Int
    var used: Int
    var remaining: Int
    var blocked: Bool
    var serverBlocked: Bool
    var period: String
    var resetAtMillis: Double
}
struct TMapReservation: Codable {
    var keyID: String
    var period: String
    var apiID: Int
}
struct TMapQuotaChange: Decodable {
    var ledger: TMapQuotaLedger
    var quotas: [TMapQuota]?
    var reservation: TMapReservation?
}
struct TMapRequest: Codable {
    var apiID: Int
    var url: String
    var body: String
    var wireIDs: [String: String]
    var endNodeID: String?
}
struct TMapTimeStop: Decodable, Identifiable {
    var id: String
    var name: String
    var wishStartTime: String
    var wishEndTime: String
    var viaTime: Int
    var windowCount: Int
}
struct TMapTimeInputs: Decodable {
    var startTime: String
    var stops: [TMapTimeStop]
    var notes: [String]
}
struct TMapRow: Codable, Identifiable {
    var id: Int { position }
    var position: Int
    var visitID: String
    var travelSeconds: Int
    var distanceMeters: Double
    var arriveTime: String
    var completeTime: String
    var workStartTime: String
    var deliverySeconds: Int?
    var waitSeconds: Int?
    var tollWon: Double?
    var coordinate: TMapCoordinate?
    var detailAddress: String
    var poiID: String
    var groupKey: String
    var scheduleIssues: [String]
}
struct TMapPath: Codable, Identifiable {
    var id: Int
    var coordinates: [TMapCoordinate]
}
struct TMapRoute: Codable {
    var apiID: Int
    var fetchedAtMillis: Double
    var expiresAtMillis: Double
    var rows: [TMapRow]
    var legs: [DeliveryLeg]
    var paths: [TMapPath]
    var totalTravelSeconds: Int
    var totalDistanceMeters: Double
    var totalTollWon: Double?
    var knownTollWon: Double
    var unknownTollCount: Int
    var providerTotalDistanceMeters: Double?
    var providerTotalTravelSeconds: Int?
    var providerTotalTollWon: Double?
    var totalDeliverySeconds: Int?
    var totalWaitSeconds: Int?
    var requestedDepartureTime: String
    var reportedDepartureTime: String
    var returnTime: String
    var elapsedSeconds: Int?
    var warnings: [String]
}
struct TMapErrorInfo: Decodable { var quota: Bool; var message: String }
private struct TMapEnvelope<T: Decodable>: Decodable {
    var ok: Bool
    var value: T?
    var message: String?
}

enum TMapBridge {
    static func call<T: Decodable>(_ method: String, _ input: [String: Any], as type: T.Type) throws -> T {
        guard let context = JSContext() else { throw PlannerFailure.message("티맵 처리기를 열지 못했습니다.") }
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        context.evaluateScript(TMapEngineSource.source)
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "티맵 처리 오류") }
        let value = context.objectForKeyedSubscript("DeliveryTMap")?.invokeMethod(method + "JSON", withArguments: [String(decoding: data, as: UTF8.self)])
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "티맵 처리 오류") }
        guard let text = value?.toString(), let output = text.data(using: .utf8) else { throw PlannerFailure.message("티맵 결과를 읽지 못했습니다.") }
        let envelope = try JSONDecoder().decode(TMapEnvelope<T>.self, from: output)
        guard envelope.ok, let result = envelope.value else { throw PlannerFailure.message(envelope.message ?? "티맵 처리 실패") }
        return result
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func timingPlan(_ plan: DeliveryPlan) -> [String: Any] {
        [
            "planDate": plan.planDate, "startMinute": plan.startMinute,
            "visits": plan.visits.map { visit -> [String: Any] in
                ["id": visit.id, "name": visit.name, "serviceMinutes": visit.serviceMinutes,
                 "arrivalWindowsText": visit.arrivalWindowsText, "avoidWindowsText": visit.avoidWindowsText,
                 "allowEarlyArrival": visit.allowEarlyArrival]
            }
        ]
    }
    static func timeInputs(_ plan: DeliveryPlan) throws -> TMapTimeInputs {
        try call("timeInputs", ["plan": timingPlan(plan)], as: TMapTimeInputs.self)
    }
    static func fingerprintData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func coordinate(_ plan: DeliveryPlan, id: String) -> TMapCoordinate? {
        if id == "depot", let value = plan.tmapOrigin { return value }
        if id == "destination", let value = plan.destination?.tmapCoordinate { return value }
        if let value = plan.visits.first(where: { $0.id == id })?.tmapCoordinate { return value }
        guard let access = plan.access(id), access.curbConfirmed, let token = access.curbPoint?.token else { return nil }
        let parts = token.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite, abs(x) > 1_000_000 else { return nil }
        return TMapCoordinate(longitude: x / 20037508.342789244 * 180, latitude: atan(sinh(y / 6378137)) * 180 / .pi)
    }
}
