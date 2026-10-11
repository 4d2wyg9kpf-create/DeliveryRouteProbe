import Foundation
import Combine

@MainActor
final class HousingStore: ObservableObject {
    @Published private(set) var regions: [HousingRegionSummary] = []
    @Published private(set) var edits: [HousingEdit] = []
    @Published private(set) var complexes: [HousingComplex] = []
    @Published var errorMessage: String?
    @Published var progress = ""
    @Published var isBusy = false
    private let directory: URL
    private var index: HousingIndex?
    private var searchRegion = ""
    private var searchKeyword = ""
    private var syncFolderIdentity = ""
    private var writable = true
    private var published = Set<String>()
    private var ready = Set<String>()
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteProbe/Housing", isDirectory: true)
        do {
            index = try HousingIndex(directory: self.directory)
            regions = try index!.summaries()
            if FileManager.default.fileExists(atPath: self.directory.path) {
                for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("region-") && file.pathExtension == "json" {
                    let code = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "region-", with: "")
                    if !regions.contains(where: { $0.code == code }) { let region = try Self.decode(Data(contentsOf: file)); try index!.replace(region); regions.append(HousingRegionSummary(region)) }
                }
                let file = self.directory.appendingPathComponent("edits.json")
                if FileManager.default.fileExists(atPath: file.path) { edits = try DeviceShareCodec.decode([HousingEdit].self, Data(contentsOf: file)); try Self.validate(edits) }
            }
            if !regions.contains(where: { $0.code == "1168010300" }) {
                let seed = try Self.decode(Data(HousingSeed.source.utf8)); try importRegion(seed, share: false)
            }
            ready = Set(regions.map(\.code)); publish()
        } catch { writable = false; errorMessage = "공동주택 보관 자료를 읽지 못했습니다. 기존 자료는 보존했습니다. " + error.localizedDescription }
    }
    private func publish() {
        regions.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        do {
            let sources = try index?.search(region: searchRegion, keyword: searchKeyword, sourceIDs: Set(edits.flatMap(\.sourceIDs))) ?? []
            complexes = HousingCatalog.effective(sources: sources, edits: edits).filter { (searchRegion.isEmpty || $0.regionCode == searchRegion) && (searchKeyword.isEmpty || ($0.name + $0.address + ($0.fields["jibunAddress"] ?? "")).localizedCaseInsensitiveContains(searchKeyword)) }
        } catch { errorMessage = error.localizedDescription }
    }
    func search(region: String, keyword: String) async {
        searchRegion = region; searchKeyword = keyword
        let edits = edits, directory = directory, ids = Set(edits.flatMap(\.sourceIDs))
        do {
            let sources = try await Task.detached(priority: .utility) { try HousingIndex.search(directory: directory, region: region, keyword: keyword, sourceIDs: ids) }.value
            guard searchRegion == region, searchKeyword == keyword else { return }
            complexes = HousingCatalog.effective(sources: sources, edits: edits).filter { (region.isEmpty || $0.regionCode == region) && (keyword.isEmpty || ($0.name + $0.address + ($0.fields["jibunAddress"] ?? "")).localizedCaseInsensitiveContains(keyword)) }
        } catch { errorMessage = error.localizedDescription }
    }
    func originalRegion(_ code: String) throws -> HousingRegion { try Self.decode(Data(contentsOf: directory.appendingPathComponent("region-" + code + ".json"))) }
    func exportRegions(_ code: String) throws -> [HousingRegion] {
        let selected = regions.filter { code.isEmpty || $0.code == code }
        guard !code.isEmpty || selected.reduce(0, { $0 + $1.sourceCount }) <= 20_000 else { throw PlannerFailure.message("큰 자료는 법정동을 선택해 나누어 내보내세요.") }
        return try selected.map { try originalRegion($0.code) }
    }
    nonisolated static func decode(_ data: Data) throws -> HousingRegion {
        guard data.count <= 50_000_000 else { throw DeviceShareError.invalid }
        let region = try JSONDecoder().decode(HousingRegion.self, from: data); try region.validate(); return region
    }
    nonisolated static func validate(_ edits: [HousingEdit]) throws {
        guard edits.count <= 5_000, Set(edits.map(\.id)).count == edits.count,
              edits.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 200 && $0.sourceIDs.count <= 500 && $0.fields.count <= 30 && $0.fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) && ($0.coordinate.map(KakaoRouteAPI.valid) ?? true) }) else { throw DeviceShareError.invalid }
    }
    func importRegion(_ incoming: HousingRegion, share: Bool = true) throws {
        var region = incoming
        guard writable else { throw DeviceShareError.unavailable }; try region.validate()
        let existing = regions.first { $0.code == region.code }
        if existing != nil {
            let local = try originalRegion(region.code), merged = try local.merging(region)
            if try DeviceShareCodec.encode(merged) == DeviceShareCodec.encode(local) { return }
            region = merged
            if merged.generation <= local.generation { region.generation = max(Date().timeIntervalSince1970 * 1000, local.generation + 1) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DeviceShareCodec.encode(region).write(to: directory.appendingPathComponent("region-" + region.code + ".json"), options: .atomic)
        try index?.replace(region)
        regions.removeAll { $0.code == region.code }; regions.append(HousingRegionSummary(region)); publish()
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
    func restore(_ id: String) throws {
        var next = edits; guard let index = next.firstIndex(where: { $0.id == id }) else { return }; next[index].hidden = false; try commit(next)
    }
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
        let selected = complexes.filter { ids.contains($0.id) }; guard selected.count == ids.count, selected.count > 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerFailure.message("단지를 2개 이상 선택하고 합칠 이름을 입력하세요.") }
        var next = edits
        for complex in selected {
            next.removeAll { $0.id == complex.id }
            next.append(HousingEdit(id: complex.id, sourceIDs: complex.sourceIDs, regionCode: complex.regionCode, fields: complex.fields, coordinate: complex.coordinate, hidden: true))
        }
        next.append(HousingEdit(id: "user:" + UUID().uuidString, sourceIDs: Array(Set(selected.flatMap(\.sourceIDs))).sorted(), regionCode: selected[0].regionCode,
            fields: Dictionary(uniqueKeysWithValues: HousingField.allCases.map { ($0.rawValue, $0 == .name ? name : "") }), coordinate: selected[0].coordinate))
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
        if syncFolderIdentity != folder.absoluteString { published.removeAll(); ready.formUnion(regions.map(\.code)); syncFolderIdentity = folder.absoluteString }
        let current = Dictionary(regions.map { ($0.code, $0.generation) }, uniquingKeysWith: max)
        let incoming = try await Task.detached(priority: .utility) { try HousingFolderIO.read(folder, current: current) }.value
        for name in incoming {
            let region = try await Task.detached(priority: .utility) { try HousingFolderIO.readFile(name, folder: folder) }.value
            try importRegion(region, share: false)
        }
        for summary in regions where ready.contains(summary.code) {
            let data = try DeviceShareCodec.encode(originalRegion(summary.code))
            let key = summary.code + "-" + String(Int(summary.generation)) + "-" + DeviceShareCodec.digest(data).prefix(12)
            guard !published.contains(key) else { continue }
            try await Task.detached(priority: .utility) { try HousingFolderIO.write([(key, data)], folder: folder) }.value
            published.insert(key)
            if regions.first(where: { $0.code == summary.code })?.generation == summary.generation { ready.remove(summary.code) }
        }
    }
}
enum HousingFolderIO {
    static func read(_ folder: URL, current: [String: Double]) throws -> [String] {
        let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let directory = folder.appendingPathComponent("DeliveryRouteShare/housing-originals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var coordinationError: NSError?; var result: [String] = []; var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &coordinationError) { root in
            do {
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]); guard files.count <= 100_000 else { throw DeviceShareError.invalid }
                var latest: [String: (Double, String)] = [:]
                for file in files where file.pathExtension == "json" {
                    let name = file.deletingPathExtension().lastPathComponent, parts = name.split(separator: "-")
                    guard parts.count == 3, parts[0].count == 10, parts[2].count == 12, let generation = Double(parts[1]), generation > (current[String(parts[0])] ?? 0) else { continue }
                    let code = String(parts[0])
                    if latest[code] == nil || latest[code]!.0 < generation { latest[code] = (generation, name) }
                }
                result = latest.values.map(\.1).sorted()
            } catch { failure = error }
        }
        if let failure { throw failure }; if coordinationError != nil { throw DeviceShareError.unavailable }; return result
    }
    static func readFile(_ name: String, folder: URL) throws -> HousingRegion {
        guard name.range(of: #"^\d{10}-\d{1,16}-[a-f0-9]{12}$"#, options: .regularExpression) != nil else { throw DeviceShareError.invalid }
        let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent("DeliveryRouteShare/housing-originals/" + name + ".json")
        var coordinationError: NSError?; var result: Result<HousingRegion, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            result = Result {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 50_000_000 else { throw DeviceShareError.invalid }
                let data = try Data(contentsOf: url), region = try HousingStore.decode(data), parts = name.split(separator: "-")
                guard region.code == String(parts[0]), Int(region.generation) == Int(parts[1]), DeviceShareCodec.digest(data).hasPrefix(String(parts[2])) else { throw DeviceShareError.invalid }
                return region
            }
        }
        if coordinationError != nil { throw DeviceShareError.unavailable }; guard let result else { throw DeviceShareError.unavailable }; return try result.get()
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
