import Foundation
import Combine

enum NaverImportDestination: String, CaseIterable, Identifiable {
    case customers, sites
    var id: String { rawValue }
    var title: String { self == .customers ? "티맵 거래처 목록" : "입지 평가대상지 목록" }
}

struct SiteTarget: Codable, Identifiable {
    var id: String
    var name: String
    var address: String
    var coordinate: TMapCoordinate
    var capture: NaverPlaceCapture
    var folders: [String]
    var addedAt: Date
}
private struct SiteTargetArchive: Codable {
    var version = 1
    var records: [SiteTarget] = []
}

@MainActor
final class SiteTargetStore: ObservableObject {
    @Published private(set) var records: [SiteTarget] = []
    @Published var errorMessage: String?
    private let fileURL: URL
    private var writable = true

    init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteProbe", isDirectory: true)
        fileURL = folder.appendingPathComponent("site-targets.json")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                guard data.count <= 20_000_000 else { throw PlannerFailure.message("평가대상지 보관함 크기를 확인해 주세요.") }
                let archive = try JSONDecoder().decode(SiteTargetArchive.self, from: data)
                guard archive.version == 1, archive.records.count <= 5_000,
                      Set(archive.records.map(\.id)).count == archive.records.count else { throw PlannerFailure.message("평가대상지 보관함 형식이 다릅니다.") }
                for record in archive.records {
                    let verified = try NaverPlaceBridge.validate(record.capture)
                    guard let coordinate = verified.coordinate,
                          coordinate.latitude == record.coordinate.latitude,
                          coordinate.longitude == record.coordinate.longitude else { throw PlannerFailure.message("저장된 평가대상지 좌표를 확인해 주세요.") }
                }
                records = archive.records
            }
        } catch { writable = false; errorMessage = "기존 평가대상지 기록을 보존했습니다. \(error.localizedDescription)" }
    }

    @discardableResult
    func save(_ capture: NaverPlaceCapture, name: String? = nil, folder: String = "") throws -> Bool {
        let capture = try NaverPlaceBridge.validate(capture)
        guard let coordinate = capture.coordinate else { throw PlannerFailure.message("좌표를 확인한 장소만 평가대상지에 저장할 수 있습니다.") }
        let title = (name ?? capture.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PlannerFailure.message("장소 이름을 입력하세요.") }
        var next = records
        let existing = try next.firstIndex { previous in
            if previous.capture.selectionKey == capture.selectionKey { return true }
            return try NaverPlaceBridge.call("customerMatches", ["first": try TMapBridge.object(previous.capture), "second": try TMapBridge.object(capture)], as: Bool.self)
        }
        let group = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = existing {
            next[index].name = title; next[index].address = capture.preferredAddress
            next[index].coordinate = coordinate; next[index].capture = capture
            if !group.isEmpty, !next[index].folders.contains(group) { next[index].folders.append(group) }
        } else {
            guard next.count < 5_000 else { throw PlannerFailure.message("평가대상지는 최대 5,000곳까지 보관합니다.") }
            next.append(SiteTarget(id: UUID().uuidString, name: title, address: capture.preferredAddress,
                                   coordinate: coordinate, capture: capture, folders: group.isEmpty ? [] : [group], addedAt: Date()))
        }
        try commit(next)
        return existing == nil
    }
    func remove(_ id: String) throws { try commit(records.filter { $0.id != id }) }
    private func commit(_ next: [SiteTarget]) throws {
        guard writable else { throw PlannerFailure.message("평가대상지 보관함 오류를 해결한 뒤 저장해 주세요.") }
        let data = try JSONEncoder().encode(SiteTargetArchive(records: next))
        guard data.count <= 20_000_000 else { throw PlannerFailure.message("평가대상지 보관함이 너무 큽니다.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        records = next; errorMessage = nil
    }
}

@MainActor
enum NaverImportSink {
    @discardableResult
    static func save(_ capture: NaverPlaceCapture, name: String? = nil, folder: String = "",
                     destination: NaverImportDestination, customers: NaverCustomerStore, sites: SiteTargetStore?) throws -> Bool {
        switch destination {
        case .customers: return try customers.save(capture, name: name, folder: folder)
        case .sites:
            guard let sites else { throw PlannerFailure.message("평가대상지 목록을 열지 못했습니다.") }
            return try sites.save(capture, name: name, folder: folder)
        }
    }
}
