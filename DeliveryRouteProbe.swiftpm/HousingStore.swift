import Foundation
import Combine

@MainActor
final class HousingStore: ObservableObject {
    @Published private(set) var regions: [HousingRegion] = []
    @Published private(set) var edits: [HousingEdit] = []
    @Published private(set) var complexes: [HousingComplex] = []
    @Published var errorMessage: String?
    @Published var progress = ""
    @Published var isBusy = false
    private let directory: URL
    private var writable = true
    private var published = Set<String>()
    private var ready = Set<String>()
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteProbe/Housing", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: self.directory.path) {
                for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("region-") && file.pathExtension == "json" {
                    let region = try Self.decode(Data(contentsOf: file)); regions.append(region)
                }
                let file = self.directory.appendingPathComponent("edits.json")
                if FileManager.default.fileExists(atPath: file.path) { edits = try DeviceShareCodec.decode([HousingEdit].self, Data(contentsOf: file)); try Self.validate(edits) }
            }
            publish()
        } catch { writable = false; errorMessage = "공동주택 보관 자료를 읽지 못했습니다. 기존 자료는 보존했습니다. " + error.localizedDescription }
    }
    private func publish() { regions.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }; complexes = HousingCatalog.effective(regions: regions, edits: edits) }
    nonisolated static func decode(_ data: Data) throws -> HousingRegion {
        guard data.count <= 50_000_000 else { throw DeviceShareError.invalid }
        let region = try JSONDecoder().decode(HousingRegion.self, from: data); try region.validate(); return region
    }
    nonisolated static func validate(_ edits: [HousingEdit]) throws {
        guard edits.count <= 5_000, Set(edits.map(\.id)).count == edits.count,
              edits.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 200 && $0.sourceIDs.count <= 500 && $0.fields.count <= 30 && $0.fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) && ($0.coordinate.map(KakaoRouteAPI.valid) ?? true) }) else { throw DeviceShareError.invalid }
    }
    func importRegion(_ region: HousingRegion, share: Bool = true) throws {
        guard writable else { throw DeviceShareError.unavailable }; try region.validate()
        let existing = regions.first { $0.code == region.code }
        if let existing, existing.generation > region.generation { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DeviceShareCodec.encode(region).write(to: directory.appendingPathComponent("region-" + region.code + ".json"), options: .atomic)
        regions.removeAll { $0.code == region.code }; regions.append(region); publish()
        if share { ready.insert(region.code); try DeviceShareHooks.changed() } else { ready.remove(region.code) }
    }
    func shareRegion(_ code: String) throws { ready.insert(code); try DeviceShareHooks.changed() }
    func edit(_ complex: HousingComplex, fields: [String: String], coordinate: TMapCoordinate? = nil) throws {
        var next = edits; let index = next.firstIndex { $0.id == complex.id }
        var value = index.map { next[$0] } ?? HousingEdit(id: complex.id, sourceIDs: complex.sourceIDs, regionCode: complex.regionCode)
        value.fields.merge(fields) { _, incoming in incoming }; if let coordinate { value.coordinate = coordinate }
        if let index { next[index] = value } else { next.append(value) }; try commit(next)
    }
    func importEdits(_ incoming: [HousingEdit]) throws {
        try Self.validate(incoming)
        var next = Dictionary(edits.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for edit in incoming { next[edit.id] = edit }; try commit(next.values.sorted { $0.id < $1.id })
    }
    func reset(_ id: String) throws { try commit(edits.filter { $0.id != id }) }
    func hide(_ complex: HousingComplex) throws {
        var next = edits; next.removeAll { $0.id == complex.id }
        next.append(HousingEdit(id: complex.id, sourceIDs: complex.sourceIDs, regionCode: complex.regionCode, fields: complex.fields, coordinate: complex.coordinate, hidden: true)); try commit(next)
    }
    @discardableResult
    func add(name: String, regionCode: String, fields: [String: String] = [:], coordinate: TMapCoordinate? = nil, sourceIDs: [String] = []) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerFailure.message("단지명을 입력하세요.") }
        var fields = fields; fields[HousingField.name.rawValue] = name
        let id = "user:" + UUID().uuidString
        try commit(edits + [HousingEdit(id: id, sourceIDs: sourceIDs, regionCode: regionCode, fields: fields, coordinate: coordinate)]); return id
    }
    func merge(_ ids: Set<String>, name: String) throws {
        let selected = complexes.filter { ids.contains($0.id) }; guard selected.count == ids.count, selected.count > 1, Set(selected.map(\.regionCode)).count == 1 else { throw PlannerFailure.message("같은 법정동의 단지를 2개 이상 선택하세요.") }
        var next = edits
        for complex in selected {
            next.removeAll { $0.id == complex.id }
            next.append(HousingEdit(id: complex.id, sourceIDs: complex.sourceIDs, regionCode: complex.regionCode, fields: complex.fields, coordinate: complex.coordinate, hidden: true))
        }
        next.append(HousingEdit(id: "user:" + UUID().uuidString, sourceIDs: Array(Set(selected.flatMap(\.sourceIDs))).sorted(), regionCode: selected[0].regionCode,
            fields: [HousingField.name.rawValue: name], coordinate: selected[0].coordinate))
        try commit(next)
    }
    private func commit(_ next: [HousingEdit]) throws {
        guard writable else { throw DeviceShareError.unavailable }; try Self.validate(next)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DeviceShareCodec.encode(next).write(to: directory.appendingPathComponent("edits.json"), options: .atomic)
        edits = next; publish(); try DeviceShareHooks.changed()
    }
    func sharingSnapshot() throws -> DeviceShareSnapshot {
        guard writable else { throw DeviceShareError.unavailable }; var result = DeviceShareSnapshot()
        for edit in edits { result.values["housing/" + edit.id] = try DeviceShareCodec.encode(edit) }; return result
    }
    func applySharing(_ replica: DeviceShareReplica) throws {
        var next: [HousingEdit] = []
        for (key, record) in replica.records where key.hasPrefix("housing/") {
            if let data = record.value { let edit = try DeviceShareCodec.decode(HousingEdit.self, data); guard key == "housing/" + edit.id else { throw DeviceShareError.invalid }; next.append(edit) }
        }
        next.sort { $0.id < $1.id }
        if try DeviceShareCodec.encode(next) != DeviceShareCodec.encode(edits.sorted { $0.id < $1.id }) { try commit(next) }
    }
    // Immutable source snapshots are separate from the small per-device edit replicas.
    // Different collectors never overwrite the same shared source file.
    func synchronizeSources(_ folder: URL) async throws {
        guard writable else { throw DeviceShareError.unavailable }
        let current = Dictionary(regions.map { ($0.code, $0.generation) }, uniquingKeysWith: max)
        let incoming = try await Task.detached(priority: .utility) { try HousingFolderIO.read(folder, current: current) }.value
        for region in incoming { try importRegion(region, share: false) }
        let outgoing = try regions.compactMap { region -> (String, Data)? in
            guard ready.contains(region.code) else { return nil }
            let data = try DeviceShareCodec.encode(region); let key = region.code + "-" + String(Int(region.generation)) + "-" + DeviceShareCodec.digest(data).prefix(12)
            return published.contains(key) ? nil : (key, data)
        }
        try await Task.detached(priority: .utility) { try HousingFolderIO.write(outgoing, folder: folder) }.value
        published.formUnion(outgoing.map(\.0))
    }
}
enum HousingFolderIO {
    static func read(_ folder: URL, current: [String: Double]) throws -> [HousingRegion] {
        let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let directory = folder.appendingPathComponent("DeliveryRouteShare/housing-originals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var error: NSError?; var result: [HousingRegion] = []; var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &error) { root in
            do {
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]); guard files.count <= 100_000 else { throw DeviceShareError.invalid }
                var latest: [String: HousingRegion] = [:]
                for file in files where file.pathExtension == "json" {
                    let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
                    guard parts.count == 3, let generation = Double(parts[1]), generation > (current[String(parts[0])] ?? 0) else { continue }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 50_000_000 else { throw DeviceShareError.invalid }
                    let data = try Data(contentsOf: file), region = try HousingStore.decode(data)
                    guard region.code == String(parts[0]), Int(region.generation) == Int(generation), DeviceShareCodec.digest(data).hasPrefix(String(parts[2])) else { throw DeviceShareError.invalid }
                    if latest[region.code] == nil || latest[region.code]!.generation < region.generation { latest[region.code] = region }
                }
                result = Array(latest.values)
            } catch { failure = error }
        }
        if let failure { throw failure }; if error != nil { throw DeviceShareError.unavailable }; return result
    }
    static func write(_ values: [(String, Data)], folder: URL) throws {
        guard !values.isEmpty else { return }
        let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
        var error: NSError?; var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &error) { root in
            do {
                let directory = root.appendingPathComponent("DeliveryRouteShare/housing-originals", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (name, data) in values {
                    let file = directory.appendingPathComponent(name + ".json")
                    if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
                }
            } catch { failure = error }
        }
        if let failure { throw failure }; if error != nil { throw DeviceShareError.unavailable }
    }
}
