import Foundation

struct TripEvent: Codable, Identifiable {
    var id = UUID().uuidString
    var type: String
    var minute: Int
    var endMinute: Int? = nil
    var toID: String? = nil
    var legID: String? = nil
    var actions: [CargoAction]? = nil
    var allowVariance: Bool? = nil
    var lotID: String? = nil
    var operation: String? = nil
    var quantity: Int? = nil
    var note: String? = nil
    var column: CargoColumn? = nil
    var routeUpdate: TripRouteUpdate? = nil

    var label: String {
        ["start": "회사 출발", "arrive": "도착", "work": "실제 상하차·재배치",
         "complete": "거래처 작업 완료", "reopen": "작업 다시 열기", "depart": "출발",
         "rest": "실제 휴식", "clock": "시각 갱신", "urgent": "다음 방문 지정",
         "target": "주문 수량 변경", "addPosition": "재배치 자리 추가", "routeUpdate": "경로·이동시간 갱신"][type] ?? type
    }
}

struct TripSession: Codable {
    var schemaVersion: Int
    var id: String
    var plan: DeliveryPlan
    var createdAt: String
    var events: [TripEvent]
    var voidedEvents: [TripEvent]
    var guidance: TripGuidance?

    var effectivePlan: DeliveryPlan {
        var current = plan
        for event in events where event.type == "routeUpdate" {
            if let leg = event.routeUpdate?.leg, let index = current.legs.firstIndex(where: { $0.id == leg.id }) {
                current.legs[index] = leg
            }
        }
        return current
    }
}

struct TripRouteUpdate: Codable {
    let expectedLegFingerprint: String
    let previousMinutes: Int
    let leg: DeliveryLeg
    let reusedChecks: Bool
}

struct TripRouteDraft: Codable {
    var leg: DeliveryLeg
    let expectedLegFingerprint: String
    let previousMinutes: Int
    let previousCapturedAt: String?
    let sameGuides: Bool
    let reusedChecks: Bool
    let baseBasis: String
}

struct TripRouteProposal: Decodable {
    let baseBasis: String
    let event: TripEvent
    let beforeFinishMinute: Int?
    let result: PlannerResult?
    let hasCandidate: Bool
    let messages: [String]
}

struct TripRouteCommit: Encodable {
    let baseBasis: String
    let event: TripEvent
}

struct TripGuidance: Codable {
    let schemaVersion: Int
    let basis: String
    let resultJSON: String?
    let resultFingerprint: String
    let generatedAt: String
    let message: String
}

struct DriveStep: Decodable, Identifiable {
    var id: Int { index }
    let index: Int
    let type: String
    let instruction: String
    let distanceText: String
}

struct DriveRoute: Decodable {
    let legID: String
    let fromID: String
    let toID: String
    let destinationName: String
    let routeURL: String?
    let minutes: Int
    let distanceMeters: Double?
    let capturedAt: String?
    let routeLabel: String
    let source: String
    let departureMinute: Int?
    let arrivalMinute: Int?
    let serviceStartMinute: Int?
    let note: String
    let accessNote: String
    let arrivalWindowsText: String
    let avoidWindowsText: String
    let curbName: String
    let entranceName: String
    let directionValidated: Bool
    let heightValidated: Bool
    let heightMM: Int?
    let class1TollWon: Int?
    let roadConditionsEnabled: Bool
    let guides: [DriveStep]
    let sections: [RoadSection]
}

struct DriveUpcoming: Decodable, Identifiable {
    var id: String { visitID }
    let visitID: String
    let position: Int
    let arrivalMinute: Int
    let readyMinute: Int
    let current: Bool
}

struct DriveStatus: Decodable {
    let scheduleFresh: Bool
    let needsRefresh: Bool
    let hasCandidate: Bool
    let generatedAt: String?
    let message: String
    let route: DriveRoute?
    let upcoming: [DriveUpcoming]
    let finishMinute: Int?
    let rest: PlannerRest?
    let restBeforeDeparture: Bool
    let workNotBefore: Int?
    let canDepart: Bool
    let departureIssue: String
}

struct DriveComparison: Decodable {
    let legID: String
    let sameStops: Bool
    let sameGuides: Bool
    let heightConfirmed: Bool
    let plannedMinutes: Int
    let observedMinutes: Double?
    let observedAt: String?
    let sourceTimeText: String
    let messages: [String]
    let estimatesApplied: Bool
}

struct TripTransit: Decodable {
    let fromID: String
    let toID: String
    let legID: String
    let startMinute: Int
}

struct TripActualRest: Decodable {
    let visitID: String
    let startMinute: Int
    let endMinute: Int
    let qualifies: Bool
}

struct TripVariance: Decodable, Identifiable {
    var id: String { visitID + ":" + lotID + ":" + operation }
    let visitID: String
    let lotID: String
    let kind: String
    let operation: String
    let planned: Int
    let original: Int
    let actual: Int
    let complete: Bool
}

struct TripPosition: Decodable {
    let lotID: String
    let columnID: String
    let kind: String
    let quantity: Int
    let top: Bool
}

struct TripReport: Decodable {
    let phase: String
    let currentID: String
    let clock: Int
    let originDepartureMinute: Int
    let completedIDs: [String]
    let transit: TripTransit?
    let restTaken: Bool
    let rests: [TripActualRest]
    let warnings: [String]
    let variance: [TripVariance]
    let suggestedActions: [CargoAction]
    let suggestionMessage: String
    let suggestedHandlingMinutes: Int
    let positions: [TripPosition]
    let snapshot: CargoSnapshot
    let cargoConfig: CargoPlan
    let priorityNextID: String
    let canDepart: Bool
    let departureIssue: String
    let travelMinutes: Int

    var isStopped: Bool { ["atStop", "ready"].contains(phase) }
    var hasCargo: Bool { snapshot.inventory.contains { $0.quantity > 0 } }
    var phaseLabel: String {
        ["driving": "이동 중", "atStop": "거래처 작업 중", "ready": "작업 완료 · 정차 중", "returned": "회사 복귀"][phase] ?? phase
    }
}

struct TripEnvelope: Decodable {
    let ok: Bool
    let trip: TripSession?
    let report: TripReport?
    let result: PlannerResult?
    let errors: [String]
    let drive: DriveStatus?
    let comparison: DriveComparison?
    let routeDraft: TripRouteDraft?
    let routeProposal: TripRouteProposal?
}

enum CargoActionText {
    static func text(_ action: CargoAction, config: CargoPlan) -> String {
        func name(_ id: String) -> String { config.columns.first { $0.id == id }?.name ?? id }
        let goods = "\(CargoKind.label(action.kind)) \(action.quantity)개"
        if action.operation == "relocate" {
            return "\(name(action.fromColumnID ?? "")) → \(name(action.toColumnID ?? action.columnID)) · \(goods) 옮기기"
        }
        return "\(name(action.columnID)) · \(goods) \(action.operation == "unload" ? "내리기" : "싣기")"
    }
}
