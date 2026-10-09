import Foundation

struct DeliveryOrder: Codable, Identifiable {
    var id: String
    var label: String
    var deliver: Int
    var pickup: Int

    static func emptyOrders() -> [DeliveryOrder] {
        [("rice20", "쌀 20kg 포대"), ("rice10", "쌀 10kg 포대"),
         ("rice4", "쌀 4kg 낱포대"), ("bag25to40", "25~40kg 포대"), ("grainBox20", "소포장 곡류 20kg 박스"),
         ("eggTray", "계란 판")].map { DeliveryOrder(id: $0.0, label: $0.1, deliver: 0, pickup: 0) }
    }
}

struct DeliveryVisit: Codable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var kind = "delivery"
    var serviceMinutes = 15
    var maxWaitMinutes = 0
    var allowEarlyArrival = true
    var canRestHere = false
    var fixedPosition = 0
    var minPosition = 1
    var maxPosition = 30
    var afterIDs: [String] = []
    var immediatelyAfterID = ""
    var arrivalWindowsText = ""
    var avoidWindowsText = ""
    var orders = DeliveryOrder.emptyOrders()
    var note = ""
    var roadAccess: StopRoadAccess?
    var tmapCoordinate: TMapCoordinate?
    var naverPlace: NaverPlaceCapture?

    var kindLabel: String {
        kind == "pickup" ? "매입처" : kind == "both" ? "매입·매출처" : "매출처"
    }
    var orderSummary: String {
        orders.filter { $0.deliver > 0 || $0.pickup > 0 }.map {
            "\($0.label) 배송 \($0.deliver) · 매입 \($0.pickup)"
        }.joined(separator: " / ")
    }
}

struct DeliveryLeg: Codable, Identifiable {
    var id = UUID().uuidString
    var fromID = "depot"
    var toID = ""
    var minutes = 10
    var source = "manual"
    var capturedAt: String? = nil
    var vehicleClass: String? = nil
    var distanceMeters: Double? = nil
    var tollWon: Double? = nil
    var arrivalSideText: String? = nil
    var pageURL: String? = nil
    var captureJSON: String? = nil
    var note = ""
    var routeLabel: String?
    var road: LegRoadEvidence?
    var apiExpiresAt: String?
    var tmapProvider: TMapProviderLeg?
    var locationInvalidated: Bool?

    var sourceLabel: String {
        source == "tmap" ? "티맵 API" : source == "naver" ? "네이버 저장값" : source == "demo" ? "가상 예제" : "직접 입력"
    }
}

struct DeliveryPlan: Codable {
    static let companyName = "맑은아침농산"
    var schemaVersion = 3
    var planDate = PlannerClock.today()
    var originName = DeliveryPlan.companyName
    var startMinute = 480
    var originWaitMinutes = 0
    var returnToOrigin = true
    var visits: [DeliveryVisit] = []
    var legs: [DeliveryLeg] = []
    var cargo: CargoPlan? = CargoPlan()
    var road: RoadPolicy?
    var originAccess: StopRoadAccess?
    var tmapOrigin: TMapCoordinate?
    var tmapBinding: TMapPlanBinding?
    var naverOrigin: NaverPlaceCapture?

    func name(_ id: String) -> String {
        id == "depot" ? originName : visits.first(where: { $0.id == id })?.name ?? "삭제된 거래처"
    }
    var nodes: [(id: String, name: String)] {
        [(id: "depot", name: originName)] + visits.map { (id: $0.id, name: $0.name) }
    }
    func leg(from: String, to: String) -> DeliveryLeg? {
        legs.first { $0.fromID == from && $0.toID == to }
    }

    static func demo(count: Int) -> DeliveryPlan {
        var plan = DeliveryPlan()
        plan.returnToOrigin = true
        for index in 0..<count {
            var visit = DeliveryVisit()
            visit.id = "sample-\(index + 1)"
            visit.name = String(format: "예제 거래처 %02d", index + 1)
            visit.serviceMinutes = 5
            visit.canRestHere = true
            visit.kind = index % 4 == 3 ? "pickup" : "delivery"
            visit.orders[0].deliver = visit.kind == "delivery" ? 5 : 0
            visit.orders[0].pickup = visit.kind == "pickup" ? 5 : 0
            plan.visits.append(visit)
        }
        if count >= 6 {
            plan.visits[2].fixedPosition = 2
            plan.visits[4].afterIDs = [plan.visits[1].id]
            plan.visits[5].immediatelyAfterID = plan.visits[4].id
            plan.visits[0].avoidWindowsText = "12:00-13:00"
        }
        let ids = ["depot"] + plan.visits.map(\.id)
        for (a, from) in ids.enumerated() {
            for (b, to) in ids.enumerated() where from != to {
                var leg = DeliveryLeg()
                leg.fromID = from; leg.toID = to
                leg.minutes = 3 + abs(a-b) + ((a*7+b*3)%4)
                leg.source = "demo"
                leg.note = "계산 시험용 가상 이동시간"
                plan.legs.append(leg)
            }
        }
        return plan
    }
}

enum PlannerClock {
    static func today() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }
    static func text(_ minute: Int) -> String {
        let day = minute / 1440, within = minute % 1440
        return (day > 0 ? "+\(day)일 " : "") + String(format: "%02d:%02d", within/60, within%60)
    }
}

struct PlannerRow: Decodable, Identifiable {
    var id: String { visitID }
    let position: Int
    let visitID: String
    let fromID: String
    let legID: String?
    let travelMinutes: Int
    let legDepartureMinute: Int
    let waitBeforeLeg: Int
    let arrivalMinute: Int
    let serviceStartMinute: Int
    let waitBeforeService: Int
    let restBeforeService: Bool
    let readyMinute: Int
    let departureMinute: Int
    let waitAfterService: Int
    let restMinutesBeforeLeg: Int
    let handlingMinutes: Int?
    let restMinutesAfterService: Int
}

struct PlannerRest: Decodable {
    let visitID: String
    let startMinute: Int
    let endMinute: Int
    let phase: String
}

struct PlannerResult: Decodable {
    let engineVersion: String
    let status: String
    let messages: [String]
    let rows: [PlannerRow]
    let finishMinute: Int?
    let lastWorkFinishMinute: Int?
    let rest: PlannerRest?
    let originDepartureMinute: Int?
    let returnMinutes: Int
    let totalTravelMinutes: Int
    let expanded: Int
    let pruned: Bool
    let completedDepth: Int
    let elapsedMilliseconds: Int
    let searchComplete: Bool
    let loadingValidated: Bool
    let cargo: CargoResult?
    let generatedCargo: CargoPlan?
    let automaticLoading: CargoAutoSummary?
    let cargoRejected: Int?
    let cargoSearchLimited: Bool?
    let remainingFromID: String?
    let replannedAtMinute: Int?
    let currentDepartureMinute: Int?
    let returnLegID: String?
    let roadEvidenceValidated: Bool?
    let heightProfileValidated: Bool?
    let class1TollValidated: Bool?
    let totalClass1TollWon: Int?
    let roadExcluded: [ExcludedRoad]?
    let roadDirectionValidated: Bool
    let liveTrafficValidated: Bool
    let globalRoadOptimalityProven: Bool
}
