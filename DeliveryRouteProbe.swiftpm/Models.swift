import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct RouteCapture: Decodable {
    let schemaVersion: Int
    let extractorVersion: String
    let mode: String
    let routePoints: [String]
    let vehicleSummary: String
    let vehicleClass: String?
    let departureTimeLabel: String
    let departureForecastText: String?
    let sourceTimeText: String?
    let candidates: [RouteCandidate]
    let detail: RouteDetail
    let quality: CaptureQuality
    let pageURL: String?
    let capturedAt: String?
    let observedVehicleSettings: ObservedVehicleSettings?
}

struct RouteCandidate: Decodable {
    let index: Int?
    let label: String
    let selected: Bool
    let durationText: String
    let durationMinutes: Double?
    let distanceText: String
    let distanceMeters: Double?
    let tollText: String
    let tollWon: Double?
    let sections: [RoadSection]
}

struct RoadSection: Decodable {
    let road: String
    let congestion: String
    let distanceText: String
    let distanceMeters: Double?
}

struct RouteDetail: Decodable {
    let visible: Bool
    let routeIndex: Int?
    let matchesSelected: Bool
    let guides: [GuideStep]
    let arrivalSide: String?
    let arrivalSideText: String
}

struct GuideStep: Decodable {
    let type: String
    let instruction: String
    let distanceText: String
    let distanceMeters: Double?
}

struct CaptureQuality: Decodable {
    let inputMatchesRoute: Bool
    let readyForSummaryImport: Bool
    let departureDirectionVerified: Bool
    let arrivalCurbVerified: Bool
    let heightClearanceVerified: Bool
    let class1FareForHeightRouteVerified: Bool
    let fullRoadGeometryAvailable: Bool
    let routeLockVerified: Bool
    let trafficFreshnessVerified: Bool
    let issues: [String]
}

struct CaptureDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
