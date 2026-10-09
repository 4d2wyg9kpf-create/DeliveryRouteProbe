import Foundation

enum CargoKind {
    static let all = ["rice20", "rice10", "rice4", "bag25to40", "grainBox20", "eggTray"]
    static func label(_ kind: String) -> String {
        ["rice20": "쌀 20kg 포대", "rice10": "쌀 10kg 포대", "rice4": "쌀 4kg 낱포대",
         "bag25to40": "25~40kg 포대", "grainBox20": "곡류 20kg 박스", "eggTray": "계란 판"][kind] ?? kind
    }
    static let directions = ["left", "right", "front", "rear"]
    static func directionName(_ direction: String) -> String {
        ["left": "왼쪽", "right": "오른쪽", "front": "앞쪽", "rear": "뒤쪽"][direction] ?? direction
    }
}

struct CargoPallet: Codable, Identifiable {
    var id = UUID().uuidString
    var name = "파렛트"
    var xMM = 0
    var yMM = 0
}

struct CargoSupport: Codable, Identifiable {
    var id: String { direction }
    var direction: String
    var targetID = ""
    var mode = "contact"
}

struct CargoColumn: Codable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var kind = "rice20"
    var xMM: Double = 0
    var yMM: Double = 0
    var rotated = false
    var palletID = ""
    var maxHeightMM = 0
    var temporaryFloor: Bool? = nil
    var alternativePosition: Bool? = nil
    var accessConfirmed = false
    var accessSource: String? = nil
    var accessMinimumHeightMM: Int? = nil
    var maxUnitsByKind: [String: Int]? = nil
    var blockedByIDs: [String] = []
    var supports = CargoKind.directions.map { CargoSupport(direction: $0) }
}

struct CargoLot: Codable, Identifiable {
    var id = UUID().uuidString
    var columnID = ""
    var kind = "rice20"
    var quantity = 1
    var loadAt = "depot"
    var unloadAt = ""
    var stackOrder = 1
}

struct CargoPlan: Codable {
    var enabled = false
    // Zero means not measured, never an assumed vehicle dimension.
    var truckWidthMM = 0
    var truckLengthMM = 0
    var truckHeightMM = 0
    var palletSideMM = 0
    var palletHeightMM = 0
    var rice20HeightMM = 0
    var rice10WidthMM = 0
    var rice10HeightMM = 0
    var rice4HeightMM = 0
    var bulkBagWidthMM = 0
    var bulkBagDepthMM = 0
    var bulkBagHeightMM = 0
    var eggSideMM = 0
    var eggTrayHeightMM = 0
    var boxWidthMM = 0
    var boxDepthMM = 0
    var boxHeightMM = 0
    var pallets: [CargoPallet] = []
    var columns: [CargoColumn] = []
    var lots: [CargoLot] = []
    var autoLayout: CargoAutoSettings? = CargoAutoSettings()
    var accessGeometry: CargoAccessGeometry? = nil
    var rehandling: CargoRehandlingSettings? = CargoRehandlingSettings()

    func size(of column: CargoColumn) -> (width: Double, depth: Double) {
        let p = Double(palletSideMM)
        let dimensions: (Double, Double)
        switch column.kind {
        case "rice20": dimensions = (p / 3, p / 2)
        case "rice10": dimensions = (Double(rice10WidthMM), p - 2 * Double(rice10WidthMM))
        case "rice4": dimensions = (p / 5, p / 3)
        case "bag25to40": dimensions = (Double(bulkBagWidthMM), Double(bulkBagDepthMM))
        case "eggTray": dimensions = (Double(eggSideMM), Double(eggSideMM))
        default: dimensions = (Double(boxWidthMM), Double(boxDepthMM))
        }
        return column.rotated ? (dimensions.1, dimensions.0) : dimensions
    }
}

struct CargoTransfer: Codable, Identifiable {
    var id = UUID().uuidString
    var kind = "rice20"
    var fromID = ""
    var toID = ""
    var quantity = 1
}

struct CargoAccessGeometry: Codable {
    var side: String
    var startMM: Int
    var widthMM: Int
}

struct CargoAutoSettings: Codable {
    var enabled = true
    var palletMode = "compare"
    var palletSide = "left"
    var accessSide = "rear"
    var doorStartMM = 0
    var doorWidthMM = 0
    var boxMaxLayers = 0
    var rice4MaxLayers = 0
    var transfers: [CargoTransfer] = []
}

struct CargoAutoSummary: Decodable {
    let attemptedLayouts: Int
    let validatedLayouts: Int
    let feasibleLayouts: Int
    let routeSeeds: Int
    let palletCount: Int
    let timeLimited: Bool
    let patternSearchComplete: Bool
    let accessSide: String
}

struct CargoInventory: Decodable, Identifiable {
    var id: String { kind }
    let kind: String
    let quantity: Int
}

struct CargoRehandlingSettings: Codable {
    var enabled = true
    var maxMovedUnits = 12
    var secondsPerUnit = 60
    var setupMinutes = 0
}

struct CargoAction: Codable {
    let lotID: String
    let columnID: String
    let kind: String
    let operation: String
    let quantity: Int
    var fromColumnID: String? = nil
    var toColumnID: String? = nil
}

struct CargoStackGroup: Decodable {
    let lotID: String
    let kind: String
    let quantity: Int
    let unloadAt: String
}

struct CargoColumnSnapshot: Decodable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let xMM: Double
    let yMM: Double
    let widthMM: Double
    let depthMM: Double
    let heightMM: Double
    let quantity: Int
    let remainingHeightMM: Double
    let lots: [CargoStackGroup]
}

struct CargoSnapshot: Decodable, Identifiable {
    var id: String { visitID }
    let visitID: String
    let inventory: [CargoInventory]
    let columns: [CargoColumnSnapshot]
    let actions: [CargoAction]
}

struct CargoResult: Decodable {
    let scope: String
    let palletCount: Int
    let truckWidthMM: Int
    let truckLengthMM: Int
    let snapshots: [CargoSnapshot]
}
