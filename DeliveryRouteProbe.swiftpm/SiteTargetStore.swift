import Foundation
import Combine

enum NaverImportDestination: String, CaseIterable, Identifiable, Hashable {
    case customers, sites
    var id: String { rawValue }
    var title: String { self == .customers ? "티맵 거래처 목록" : "입지 평가대상지 목록" }
}

struct SiteTarget: Codable, Identifiable {
    var id: String
    var name: String
    var address: String
    var coordinate: TMapCoordinate
    var capture: NaverPlaceCapture?
    var coordinateOverride: TMapCoordinate? = nil
    var housingID: String? = nil
    var building: BuildingSelection? = nil
    var buildingFacts: [String: BuildingFact]? = nil
    var effectiveCoordinate: TMapCoordinate { coordinateOverride ?? coordinate }
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
                guard data.count <= 150_000_000 else { throw PlannerFailure.message("평가대상지 보관함 크기를 확인해 주세요.") }
                let archive = try JSONDecoder().decode(SiteTargetArchive.self, from: data)
                guard archive.version == 1, archive.records.count <= 100_000,
                      Set(archive.records.map(\.id)).count == archive.records.count else { throw PlannerFailure.message("평가대상지 보관함 형식이 다릅니다.") }
                for record in archive.records {
                    if let building = record.building { try building.validate(); guard building.longitude == record.coordinate.longitude, building.latitude == record.coordinate.latitude else { throw DeviceShareError.invalid } }
                    guard Self.valid(record.coordinate), record.coordinateOverride.map(Self.valid) ?? true else { throw DeviceShareError.invalid }
                    guard let capture = record.capture else { continue }
                    let verified = try NaverPlaceBridge.call("validate", ["capture": try TMapBridge.object(capture)], as: NaverPlaceCapture.self)
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
        let capture = try NaverPlaceBridge.call("validate", ["capture": try TMapBridge.object(capture)], as: NaverPlaceCapture.self)
        guard let coordinate = capture.coordinate else { throw PlannerFailure.message("좌표를 확인한 장소만 평가대상지에 저장할 수 있습니다.") }
        let title = (name ?? capture.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PlannerFailure.message("장소 이름을 입력하세요.") }
        var next = records
        let existing = try next.firstIndex { previous in
            guard previous.building == nil else { return false }
            guard let previousCapture = previous.capture else { return false }
            if (capture.kind == "address" && capture.sharedLinkURL != nil) || (previousCapture.kind == "address" && previousCapture.sharedLinkURL != nil) {
                return try NaverPlaceBridge.call("customerMatches", ["first": try TMapBridge.object(previousCapture), "second": try TMapBridge.object(capture)], as: Bool.self)
            }
            if previousCapture.selectionKey == capture.selectionKey { return true }
            return try NaverPlaceBridge.call("customerMatches", ["first": try TMapBridge.object(previousCapture), "second": try TMapBridge.object(capture)], as: Bool.self)
        }
        let group = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = existing {
            next[index].name = title; next[index].address = capture.preferredAddress
            next[index].coordinate = coordinate; next[index].capture = capture
            if !group.isEmpty, !next[index].folders.contains(group) { next[index].folders.append(group) }
        } else {
            guard next.count < 100_000 else { throw PlannerFailure.message("평가대상지는 최대 100,000곳까지 보관합니다.") }
            next.append(SiteTarget(id: UUID().uuidString, name: title, address: capture.preferredAddress,
                                   coordinate: coordinate, capture: capture, folders: group.isEmpty ? [] : [group], addedAt: Date()))
        }
        try commit(next)
        return existing == nil
    }
    func remove(_ id: String) throws { try commit(records.filter { $0.id != id }) }
    static func valid(_ coordinate: TMapCoordinate) -> Bool {
        coordinate.longitude.isFinite && coordinate.latitude.isFinite && (124...132).contains(coordinate.longitude) && (32...40).contains(coordinate.latitude)
    }
    @discardableResult
    func saveManual(name: String, address: String, coordinate: TMapCoordinate, housingID: String? = nil) throws -> String {
        guard Self.valid(coordinate), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerFailure.message("이름과 국내 좌표를 확인하세요.") }
        var next = records
        let existing = housingID.flatMap { id in next.firstIndex { $0.housingID == id } }
        let id = existing.map { next[$0].id } ?? UUID().uuidString
        if let existing {
            next[existing].name = name; next[existing].address = address
            next[existing].coordinate = coordinate
        } else {
            guard next.count < 100_000 else { throw DeviceShareError.invalid }
            next.append(SiteTarget(id: id, name: name, address: address, coordinate: coordinate, capture: nil, housingID: housingID, folders: [], addedAt: Date()))
        }
        try commit(next); return id
    }
    func setCoordinate(_ id: String, coordinate: TMapCoordinate?) throws {
        guard coordinate.map(Self.valid) ?? true, let index = records.firstIndex(where: { $0.id == id }) else { throw DeviceShareError.invalid }
        var next = records; next[index].coordinateOverride = coordinate; try commit(next)
    }
    @discardableResult
    func saveBuilding(_ selection: BuildingSelection, facts: [String: BuildingFact]) throws -> String {
        try selection.validate()
        let name = [selection.building.name,selection.building.dongName].filter { !$0.isEmpty }.joined(separator:" ")
        let point = TMapCoordinate(longitude:selection.longitude,latitude:selection.latitude)
        var next = records
        let existing = next.firstIndex { $0.building?.identity == selection.identity }
        let id = existing.map { next[$0].id } ?? UUID().uuidString
        let target = SiteTarget(id:id,name:name.isEmpty ? selection.building.roadAddress : name,address:selection.building.roadAddress,
            coordinate:point,capture:nil,building:selection,buildingFacts:facts,folders:existing.map { next[$0].folders } ?? [],addedAt:existing.map { next[$0].addedAt } ?? Date())
        if let existing { next[existing] = target }
        else { guard next.count < 100_000 else { throw DeviceShareError.invalid }; next.append(target) }
        try commit(next); return id
    }
    static func sharingKey(_ record: SiteTarget) -> String {
        if let building = record.building { return "site/building/" + DeviceShareCodec.key(building.identity) }
        if let housingID = record.housingID { return "site/housing/" + DeviceShareCodec.key(housingID) }
        if let capture = record.capture {
            if !capture.placeID.isEmpty { return "site/place/" + capture.placeID }
            if capture.isSharedAddress { return "site/address/" + DeviceShareCodec.key(DeviceShareCodec.addressIdentity(capture.preferredAddress)) }
            return "site/selection/" + DeviceShareCodec.key(capture.selectionKey)
        }
        return "site/manual/" + record.id
    }
    func sharingSnapshot() throws -> DeviceShareSnapshot {
        guard writable else { throw DeviceShareError.unavailable }
        var result = DeviceShareSnapshot()
        for record in records { result.values[Self.sharingKey(record)] = try DeviceShareCodec.encode(record) }
        return result
    }
    func applySharing(_ replica: DeviceShareReplica) throws {
        let local = Dictionary(records.map { (Self.sharingKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var next: [SiteTarget] = []
        for (key, entry) in replica.records where key.hasPrefix("site/") {
            guard let data = entry.value else { continue }
            var record = try DeviceShareCodec.decode(SiteTarget.self, data)
            if let building = record.building { try building.validate(); guard building.longitude == record.coordinate.longitude, building.latitude == record.coordinate.latitude else { throw DeviceShareError.invalid } }
            guard key == Self.sharingKey(record), Self.valid(record.coordinate), record.coordinateOverride.map(Self.valid) ?? true else { throw DeviceShareError.invalid }
            if let capture = record.capture {
                let verified = try NaverPlaceBridge.call("validate", ["capture": try TMapBridge.object(capture)], as: NaverPlaceCapture.self)
                guard verified.coordinate?.longitude == record.coordinate.longitude, verified.coordinate?.latitude == record.coordinate.latitude else { throw DeviceShareError.invalid }
            }
            if let previous = local[key] { record.id = previous.id }
            next.append(record)
        }
        next.sort { $0.addedAt < $1.addedAt }
        if try DeviceShareCodec.encode(next) != DeviceShareCodec.encode(records) { try commit(next) }
    }
    private func commit(_ next: [SiteTarget]) throws {
        guard writable else { throw PlannerFailure.message("평가대상지 보관함 오류를 해결한 뒤 저장해 주세요.") }
        let data = try JSONEncoder().encode(SiteTargetArchive(records: next))
        guard data.count <= 150_000_000 else { throw PlannerFailure.message("평가대상지 보관함이 너무 큽니다.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        records = next; errorMessage = nil
        try DeviceShareHooks.changed()
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
