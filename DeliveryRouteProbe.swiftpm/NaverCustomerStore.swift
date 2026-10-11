import Foundation
import Combine

struct NaverCustomerRecord: Codable, Identifiable {
    var id: String
    var name: String
    var capture: NaverPlaceCapture?
    var template: DeliveryVisit
    var folders: [String]
    var coordinateOverride: TMapCoordinate? = nil
    var effectiveCoordinate: TMapCoordinate? { coordinateOverride ?? template.tmapCoordinate ?? capture?.coordinate }
}
private struct NaverCustomerArchive: Codable {
    var version = 1
    var records: [NaverCustomerRecord]
}
struct NaverSavedListSnapshot: Decodable {
    var folderID: String
    var title: String
    var total: Int
    var rows: [NaverSavedListRow]
}
struct NaverSavedListRow: Decodable {
    var index: Int
    var name: String
    var address: String
    var key: String
}
struct NaverSavedListReport {
    var title: String
    var total: Int
    var added = 0
    var updated = 0
    var failures: [String] = []
    var completed = false
    var saved: Int { added + updated }
}

@MainActor
final class NaverCustomerStore: ObservableObject {
    static let shared = NaverCustomerStore()
    @Published private(set) var records: [NaverCustomerRecord] = []
    private(set) var needsPlanMigration = true
    private var sharedDeletionKeys: Set<String> = []
    @Published var errorMessage: String?
    private var writable = true
    private let directory: URL?
    init(directory: URL? = nil) {
        self.directory = directory
        do {
            let url = try Self.fileURL(directory)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count <= 20_000_000 else { throw PlannerFailure.message("거래처 파일이 너무 큽니다.") }
                let archive = try JSONDecoder().decode(NaverCustomerArchive.self, from: data)
                guard archive.version == 1, Set(archive.records.map(\.id)).count == archive.records.count else { throw PlannerFailure.message("거래처 파일 형식을 확인해 주세요.") }
                for record in archive.records {
                    guard record.coordinateOverride.map(Self.validCoordinate) ?? true else { throw DeviceShareError.invalid }
                    if let capture = record.capture { _ = try NaverPlaceBridge.call("validate", ["capture": try TMapBridge.object(capture)], as: NaverPlaceCapture.self) }
                }
                records = archive.records
                needsPlanMigration = false
            }
        } catch { writable = false; errorMessage = "저장한 거래처를 읽지 못했습니다. 기존 파일은 보존했습니다. \(error.localizedDescription)" }
    }
    private static func fileURL(_ override: URL? = nil) throws -> URL {
        let directory = try override ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RouteProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("naver-customers.json")
    }
    @discardableResult
    func save(_ capture: NaverPlaceCapture, name: String? = nil, folder: String = "") throws -> Bool {
        guard writable else { throw PlannerFailure.message(errorMessage ?? "거래처 파일의 읽기 오류를 해결해 주세요.") }
        let valid = try NaverPlaceBridge.call("validate", ["capture": try TMapBridge.object(capture)], as: NaverPlaceCapture.self)
        guard valid.coordinate != nil else { throw PlannerFailure.message("좌표가 없는 장소는 거래처 목록에 저장하지 않습니다. 좌표를 다시 읽어 주세요.") }
        var next = records
        let existing = try next.firstIndex { record in
            if (valid.kind == "address" && valid.sharedLinkURL != nil) || (record.capture?.kind == "address" && record.capture?.sharedLinkURL != nil) {
                guard let previous = record.capture else { return false }
                return try NaverPlaceBridge.call("customerMatches", ["first": try TMapBridge.object(previous), "second": try TMapBridge.object(valid)], as: Bool.self)
            }
            if record.id == valid.selectionKey || record.capture?.selectionKey == valid.selectionKey { return true }
            guard let previous = record.capture else { return false }
            return try NaverPlaceBridge.call("customerMatches", ["first": try TMapBridge.object(previous), "second": try TMapBridge.object(valid)], as: Bool.self)
        }
        var folders = existing.map { next[$0].folders } ?? []
        if !folder.isEmpty && !folders.contains(folder) { folders.append(folder) }
        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : valid.name
        var template = existing.map { next[$0].template } ?? DeliveryVisit()
        template.name = displayName; template.naverPlace = valid
        let newID = valid.kind == "address" && valid.sharedLinkURL != nil ? UUID().uuidString : valid.selectionKey
        let record = NaverCustomerRecord(id: existing.map { next[$0].id } ?? newID, name: displayName, capture: valid, template: template, folders: folders, coordinateOverride: existing.flatMap { next[$0].coordinateOverride })
        if let index = existing { next[index] = record } else { next.append(record) }
        try commit(next)
        return existing == nil
    }
    static func validCoordinate(_ c: TMapCoordinate) -> Bool { c.longitude.isFinite && c.latitude.isFinite && (124...132).contains(c.longitude) && (32...40).contains(c.latitude) }
    func setCoordinate(_ id: String, coordinate: TMapCoordinate?) throws {
        guard coordinate.map({ $0.longitude.isFinite && $0.latitude.isFinite && (124...132).contains($0.longitude) && (32...40).contains($0.latitude) }) ?? true,
              let index = records.firstIndex(where: { $0.id == id }) else { throw DeviceShareError.invalid }
        var next = records; next[index].coordinateOverride = coordinate; try commit(next)
    }
    func remove(_ id: String) throws { try commit(records.filter { $0.id != id }) }
    // Keep registered customers apart from the visits for the current delivery.
    // Existing device plans migrate once, so unchecking a visit does not lose it.
    func remember(_ plan: DeliveryPlan) throws {
        var next = records
        var remembered = plan.visits
        if plan.naverOrigin != nil || TMapBridge.coordinate(plan, id: "depot") != nil {
            var origin = DeliveryVisit(); origin.id = "origin-depot"; origin.name = plan.originName
            origin.naverPlace = plan.naverOrigin; origin.tmapCoordinate = plan.tmapOrigin; origin.roadAccess = plan.originAccess
            if let record = next.first(where: { $0.id == plan.originCustomerID }) { origin.id = record.template.id }
            else if let capture = plan.naverOrigin,
                    let record = try next.first(where: { record in
                        guard let previous = record.capture else { return false }
                        return try NaverPlaceBridge.call("customerMatches", ["first": try TMapBridge.object(previous), "second": try TMapBridge.object(capture)], as: Bool.self)
                    }) { origin.id = record.template.id }
            remembered.append(origin)
        }
        for visit in remembered {
            let candidate = NaverCustomerRecord(id: "", name: visit.name, capture: visit.naverPlace, template: visit, folders: [])
            if sharedDeletionKeys.contains(Self.sharingKey(candidate)) { continue }
            let sharedAddress = visit.naverPlace?.kind == "address" && visit.naverPlace?.sharedLinkURL != nil
            let key = sharedAddress ? next.first(where: { $0.template.id == visit.id })?.id ?? "shared:" + visit.id : visit.naverPlace?.selectionKey ?? "manual:" + visit.id
            if next.contains(where: { $0.id == key }) { next.removeAll { $0.id != key && $0.template.id == visit.id } }
            if let index = next.firstIndex(where: { $0.id == key || $0.template.id == visit.id }) {
                next[index].template = visit; next[index].name = visit.name
                if let capture = visit.naverPlace {
                    let stored = next[index].capture
                    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let incomingDate = formatter.date(from: capture.capturedAt) ?? .distantPast
                    let storedDate = stored.flatMap { formatter.date(from: $0.capturedAt) } ?? .distantPast
                    if stored == nil || (capture.coordinate != nil && incomingDate >= storedDate) { next[index].capture = capture }
                }
                next[index].template.naverPlace = next[index].capture
            } else {
                next.append(NaverCustomerRecord(id: key, name: visit.name, capture: visit.naverPlace, template: visit, folders: []))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if try encoder.encode(NaverCustomerArchive(records: next)) != encoder.encode(NaverCustomerArchive(records: records)) { try commit(next) }
    }

    func applySelection(_ selectedIDs: Set<String>, planner: PlannerStore, curbConfirmed: Bool, originID: String = "current", endMode: String = "return", destinationID: String = "") throws {
        guard planner.autoSaveEnabled, !planner.isComputing else { throw PlannerFailure.message("배송계획 저장 상태를 먼저 확인해 주세요.") }
        try remember(planner.plan)
        let selected = try NaverPlaceBridge.call("selectCustomers", ["plan": try TMapBridge.object(planner.plan),
            "customers": try records.map { try TMapBridge.object($0) }, "selectedIDs": Array(selectedIDs), "curbConfirmed": curbConfirmed], as: DeliveryPlan.self)
        let value = try NaverPlaceBridge.call("endpoints", ["plan": try TMapBridge.object(selected), "customers": try records.map { try TMapBridge.object($0) },
            "originID": originID, "endMode": endMode, "destinationID": destinationID, "curbConfirmed": curbConfirmed], as: DeliveryPlan.self)
        planner.errorMessage = nil; planner.plan = value; planner.saveNow()
        if let error = planner.errorMessage { throw PlannerFailure.message(error) }
        planner.message = "이번 배송에는 선택한 거래처 \(value.visits.count)곳만 방문합니다."
    }
    private func commit(_ next: [NaverCustomerRecord]) throws {
        guard writable else { throw PlannerFailure.message(errorMessage ?? "거래처 파일을 저장할 수 없습니다.") }
        let data = try JSONEncoder().encode(NaverCustomerArchive(records: next))
        try data.write(to: Self.fileURL(directory), options: .atomic)
        records = next; errorMessage = nil
        needsPlanMigration = false
        try DeviceShareHooks.changed()
    }
}

extension NaverCustomerStore {
    static func sharingKey(_ record: NaverCustomerRecord) -> String {
        if let capture = record.capture {
            if !capture.placeID.isEmpty { return "customer/place/" + capture.placeID }
            if capture.isSharedAddress { return "customer/address/" + DeviceShareCodec.key(DeviceShareCodec.addressIdentity(capture.preferredAddress)) }
            if capture.kind == "address" { return "customer/named-address/" + DeviceShareCodec.key(capture.name.replacingOccurrences(of: " ", with: "") + "|" + DeviceShareCodec.addressIdentity(capture.preferredAddress)) }
            return "customer/selection/" + DeviceShareCodec.key(capture.selectionKey)
        }
        return "customer/manual/" + record.template.id
    }
    func sharingSnapshot() throws -> DeviceShareSnapshot {
        guard writable else { throw DeviceShareError.unavailable }
        var result = DeviceShareSnapshot()
        for record in records { result.values[Self.sharingKey(record)] = try DeviceShareCodec.encode(record) }
        return result
    }
    func applySharing(_ replica: DeviceShareReplica) throws {
        guard writable else { throw DeviceShareError.unavailable }
        let local = Dictionary(records.map { (Self.sharingKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var next: [NaverCustomerRecord] = []
        var deletions: Set<String> = []
        for (key, entry) in replica.records.sorted(by: { $0.key < $1.key }) where key.hasPrefix("customer/") {
            guard let data = entry.value else { deletions.insert(key); continue }
            var record = try DeviceShareCodec.decode(NaverCustomerRecord.self, data)
            guard Self.sharingKey(record) == key, !record.id.isEmpty, record.id.utf8.count <= 2_000,
                  record.name.utf8.count <= 2_000, record.folders.count <= 500 else { throw DeviceShareError.invalid }
            guard record.coordinateOverride.map(Self.validCoordinate) ?? true else { throw DeviceShareError.invalid }
            if let capture = record.capture { _ = try NaverPlaceBridge.call("validate", ["capture": try TMapBridge.object(capture)], as: NaverPlaceCapture.self) }
            if let previous = local[key] { record.id = previous.id; record.template.id = previous.template.id }
            next.append(record)
        }
        guard next.count <= 10_000, Set(next.map(\.id)).count == next.count else { throw DeviceShareError.invalid }
        if try DeviceShareCodec.encode(next) != DeviceShareCodec.encode(records) { try commit(next) }
        sharedDeletionKeys = deletions
    }
}
