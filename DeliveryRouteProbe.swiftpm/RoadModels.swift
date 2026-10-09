import Foundation
import JavaScriptCore

struct MapRoutePoint: Codable, Identifiable {
    var id: String { token }
    var token: String
    var name: String
}

struct StopRoadAccess: Codable {
    var roadType = ""
    var curbPoint: MapRoutePoint?
    var entrancePoint: MapRoutePoint?
    var bikeEntrance: BikeEntranceBinding?
    var curbEntranceToken: String?
    var approachPoint: MapRoutePoint?
    var departurePoint: MapRoutePoint?
    var curbConfirmed = false
    var note = ""
    var label: String {
        switch roadType {
        case "naverMultiLane": return "중앙선·편도 2차로 이상"
        case "twoWayNarrow": return "그 외 양방향 도로"
        case "oneWay": return "일방통행"
        default: return "도로 유형 미등록"
        }
    }
}

struct RoadPolicy: Codable {
    var enabled = false
    var requireCurb = true
    var requireHeight = true
    var requireClass1Toll = true
    var vehicleHeightMM = 0
    var clearanceMarginMM = 0
}

struct LegRoadEvidence: Codable {
    var fromSignature: String
    var toSignature: String
    var routeSignature: String
    var departureConfirmed: Bool
    var arrivalConfirmed: Bool
    var legalDirectionConfirmed: Bool
    var heightMM: Int
    var heightBasis: String
    var heightConfirmed: Bool
    var heightNote: String?
    var class1TollWon: Int?
    var fareSource: String
    var fareRouteSignature: String
    var fareCaptureJSON: String?
}

struct RoadRequest: Decodable {
    var ok: Bool
    var errors: [String]
    var url: String?
    var heightMM: Int?
    var points: [MapRoutePoint]?
}

struct RoadChange: Decodable {
    var ok: Bool
    var errors: [String]
    var leg: DeliveryLeg?
    var note: String?
}

struct ParsedMapRoute: Decodable {
    var mode: String
    var points: [MapRoutePoint]
}

struct BikeEntranceCapture: Codable {
    var version: Int
    var sourceURL: String
    var routeKey: String
    var selectedIndex: Int
    var start: MapRoutePoint
    var destination: MapRoutePoint
    var point: MapRoutePoint
    var latitude: Double
    var longitude: Double
    var mercatorX: Double
    var mercatorY: Double
    var tileZoom: Int
    var screenResolutionMeters: Double
    var destinationGapMeters: Double
    var arrivalSideText: String
    var detailSummary: String
    var finalInstruction: String
    var guideCount: Int
    var capturedAt: String
    var method: String
    var previewURL: String
}

struct BikeEntranceBinding: Codable {
    var stopID: String
    var capture: BikeEntranceCapture
    var entranceConfirmed = false
}

struct EntranceChange: Decodable {
    var ok: Bool
    var errors: [String]
    var access: StopRoadAccess?
}

struct RoadCheck: Decodable {
    var eligible: Bool
    var reasons: [String]
    var directionValidated: Bool
    var heightProfileValidated: Bool
    var class1TollValidated: Bool
    var class1TollWon: Int?
    var connected: Bool
}

struct ExcludedRoad: Decodable, Identifiable {
    var id: String { legID }
    var legID: String
    var fromID: String
    var toID: String
    var reasons: [String]
}

struct ObservedVehicleSettings: Decodable {
    var confirmed: Bool
    var heightMM: Int?
    var vehicleClass: String?
}

private struct RoadPlanContext: Encodable {
    struct Visit: Encodable { var id: String; var name: String; var roadAccess: StopRoadAccess? }
    var originName: String
    var originAccess: StopRoadAccess?
    var road: RoadPolicy?
    var visits: [Visit]
    init(_ plan: DeliveryPlan) {
        originName = plan.originName; originAccess = plan.originAccess; road = plan.road
        visits = plan.visits.map { Visit(id: $0.id, name: $0.name, roadAccess: $0.roadAccess) }
    }
}

enum RoadBridge {
    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    static func call<T: Decodable>(_ method: String, _ arguments: [String], as type: T.Type) throws -> T {
        guard let context = JSContext() else { throw PlannerFailure.message("도로 계산기를 열지 못했습니다.") }
        context.evaluateScript(RoadEngineSource.source)
        let result = context.objectForKeyedSubscript("DeliveryRoads")?.invokeMethod(method, withArguments: arguments)
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "도로 정보 해석 오류") }
        guard let text = result?.toString(), let data = text.data(using: .utf8), text != "null" else {
            throw PlannerFailure.message("네이버 길찾기의 출발·도착 지점이 포함된 주소를 읽어 주세요.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
    static func points(_ url: String) throws -> ParsedMapRoute {
        try call("pointJSON", [url], as: ParsedMapRoute.self)
    }
    static func bikeKey(_ url: String) -> String? {
        guard let route = try? points(url), route.mode == "bike", route.points.count == 2 else { return nil }
        return route.points[0].token + "/" + route.points[1].token + "/bike"
    }
    static func entrance(_ access: StopRoadAccess, capture: BikeEntranceCapture, stopID: String, currentURL: String) throws -> EntranceChange {
        try call("entranceJSON", [try json(access), try json(capture), stopID, currentURL], as: EntranceChange.self)
    }
    static func request(_ plan: DeliveryPlan, from: String, to: String) throws -> RoadRequest {
        try call("requestJSON", [try json(RoadPlanContext(plan)), from, to], as: RoadRequest.self)
    }
    static func attach(_ plan: DeliveryPlan, leg: DeliveryLeg) throws -> RoadChange {
        try call("attachJSON", [try json(RoadPlanContext(plan)), try json(leg)], as: RoadChange.self)
    }
    static func fare(_ leg: DeliveryLeg, capture: Data) throws -> RoadChange {
        try call("fareJSON", [try json(leg), String(decoding: capture, as: UTF8.self)], as: RoadChange.self)
    }
    static func inspect(_ plan: DeliveryPlan, leg: DeliveryLeg) throws -> RoadCheck {
        try call("inspectJSON", [try json(RoadPlanContext(plan)), try json(leg)], as: RoadCheck.self)
    }
}

extension DeliveryPlan {
    func access(_ id: String) -> StopRoadAccess? {
        id == "depot" ? originAccess : visits.first(where: { $0.id == id })?.roadAccess
    }
    mutating func setAccess(_ value: StopRoadAccess, id: String) {
        if id == "depot" { originAccess = value }
        else if let index = visits.firstIndex(where: { $0.id == id }) { visits[index].roadAccess = value }
    }
    func selectedLeg(_ id: String?, from: String, to: String) -> DeliveryLeg? {
        if let id = id { return legs.first(where: { $0.id == id }) }
        return leg(from: from, to: to)
    }
}
