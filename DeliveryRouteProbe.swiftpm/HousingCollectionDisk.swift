import Foundation

// The same lock serializes UI imports, sharing merges, collection journal writes,
// and checkpoints. Detached tasks never race a newer source or user correction.
final class HousingCollectionDisk: @unchecked Sendable {
    let directory: URL
    let index: HousingIndex
    private let lock = NSRecursiveLock()
    init(directory: URL, index: HousingIndex) { self.directory = directory; self.index = index }
    private func file(_ code: String) -> URL { directory.appendingPathComponent("region-" + code + ".json") }
    func read(_ code: String) throws -> HousingRegion {
        lock.lock(); defer { lock.unlock() }
        var region = try HousingStore.decode(Data(contentsOf: file(code)))
        let updates = Dictionary(try index.journal(code).map { ($0.id, $0) }, uniquingKeysWith: HousingRegion.newerSource)
        for i in region.records.indices { if let row = updates[region.records[i].id] { region.records[i] = HousingRegion.newerSource(region.records[i], row) } }
        if !updates.isEmpty { region.generation = max(region.generation, try index.summary(code)?.generation ?? region.generation) }
        return region
    }
    func merge(_ incoming: HousingRegion, edits: [HousingEdit]) throws -> HousingRegionSummary {
        lock.lock(); defer { lock.unlock() }; try incoming.validate()
        var region = incoming
        if FileManager.default.fileExists(atPath: file(incoming.code).path) {
            let local = try read(incoming.code); region = try local.merging(incoming)
            if try DeviceShareCodec.encode(region) == DeviceShareCodec.encode(local) { return HousingRegionSummary(local) }
            region.generation = max(Date().timeIntervalSince1970 * 1000, max(local.generation + 1, region.generation))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DeviceShareCodec.encode(region).write(to: file(region.code), options: .atomic)
        try index.replace(region, edits: edits); try index.clearJournal(region.code)
        return HousingRegionSummary(region)
    }
    func source(_ id: String, code: String) throws -> HousingSource? {
        lock.lock(); defer { lock.unlock() }; return try index.rawSource(id, region: code)
    }
    func save(_ incoming: HousingSource, edits: [HousingEdit]) throws -> (HousingRegionSummary, HousingSource) {
        lock.lock(); defer { lock.unlock() }
        guard HousingRegion.validSource(incoming), var summary = try index.summary(incoming.regionCode),
              let old = try index.rawSource(incoming.id, region: incoming.regionCode) else { throw DeviceShareError.invalid }
        let source = HousingRegion.newerSource(old, incoming)
        if old.detailAt == nil, source.detailAt != nil { summary.detailCount += 1 }
        summary.generation = max(Date().timeIntervalSince1970 * 1000, summary.generation + 1)
        var indexed = source; indexed.members = [source]
        indexed.fields.merge(edits.first { $0.id == source.id }?.fields ?? [:]) { _, user in user }
        try index.saveCollectedSource(source, indexed: indexed, summary: summary)
        return (summary, source)
    }
    func flush(_ code: String, reindex: Bool = false, edits: [HousingEdit] = []) throws {
        lock.lock(); defer { lock.unlock() }
        if !reindex, try index.journal(code).isEmpty { return }
        let region = try read(code)
        try DeviceShareCodec.encode(region).write(to: file(code), options: .atomic)
        if reindex { try index.replace(region, edits: edits) }
        // Clear only after the full original is atomically on disk. Replaying
        // this journal after termination between these two steps is idempotent.
        try index.clearJournal(code)
    }
    func recover(edits: [HousingEdit]) throws {
        for code in try index.journalRegions() { try flush(code, reindex: true, edits: edits) }
    }
}
