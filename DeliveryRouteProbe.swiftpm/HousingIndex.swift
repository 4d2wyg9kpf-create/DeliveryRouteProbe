import Foundation
import SQLite3

struct HousingRegionSummary: Codable, Identifiable {
    var code: String
    var sido: HousingArea
    var sigungu: HousingArea
    var dong: HousingArea
    var generation: Double
    var sourceCount: Int
    var detailCount: Int
    var kaptCount: Int? = nil
    var kaptDetailCount: Int? = nil
    var complexCount: Int? = nil
    var id: String { code }
    var title: String { "\(sido.name) \(sigungu.name) \(dong.name)" }
    init(_ region: HousingRegion) {
        code = region.code; sido = region.sido; sigungu = region.sigungu; dong = region.dong
        generation = region.generation; sourceCount = region.sourceCount; detailCount = region.detailCount
        kaptCount = region.kaptRecords?.count ?? 0; kaptDetailCount = region.kaptRecords?.filter { $0.detailAt != nil }.count ?? 0
        complexCount = HousingConsolidator.sources(region).count
    }
}
// The nationwide catalog stays on disk. Only bounded search results are decoded.
final class HousingIndex {
    let url: URL
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("search.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DeviceShareError.unavailable }
        sqlite3_busy_timeout(db, 5000)
        try run("PRAGMA journal_mode=WAL")
        try run("CREATE TABLE IF NOT EXISTS regions(code TEXT PRIMARY KEY, data BLOB NOT NULL)")
        try run("CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY, region TEXT NOT NULL, name TEXT NOT NULL, address TEXT NOT NULL, data BLOB NOT NULL)")
        try run("CREATE INDEX IF NOT EXISTS sources_region_name ON sources(region,name)")
        try run("CREATE TABLE IF NOT EXISTS raw_sources(id TEXT PRIMARY KEY, region TEXT NOT NULL, data BLOB NOT NULL)")
        try run("CREATE INDEX IF NOT EXISTS raw_sources_region ON raw_sources(region)")
    }
    deinit { sqlite3_close(db) }
    private func run(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DeviceShareError.unavailable } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DeviceShareError.unavailable }; return statement
    }
    private func bind(_ text: String, at: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, at, text, -1, Self.transient) == SQLITE_OK else { throw DeviceShareError.unavailable }
    }
    private func bind(_ data: Data, at: Int32, to statement: OpaquePointer) throws {
        let status = data.withUnsafeBytes { sqlite3_bind_blob(statement, at, $0.baseAddress, Int32(data.count), Self.transient) }
        guard status == SQLITE_OK else { throw DeviceShareError.unavailable }
    }
    private static func blob(_ statement: OpaquePointer, column: Int32 = 0) throws -> Data {
        let count = sqlite3_column_bytes(statement,column)
        guard count >= 0, count <= 50_000_000, let bytes = sqlite3_column_blob(statement,column) else { throw DeviceShareError.invalid }; return Data(bytes: bytes,count: Int(count))
    }
    func summaries() throws -> [HousingRegionSummary] {
        let s = try statement("SELECT data FROM regions ORDER BY code"); defer { sqlite3_finalize(s) }
        var records: [HousingRegionSummary] = []; var status = sqlite3_step(s)
        while status == SQLITE_ROW { records.append(try JSONDecoder().decode(HousingRegionSummary.self, from: Self.blob(s))); status = sqlite3_step(s) }
        guard status == SQLITE_DONE else { throw DeviceShareError.unavailable }; return records
    }
    func replace(_ region: HousingRegion, edits: [HousingEdit] = []) throws {
        try run("BEGIN IMMEDIATE")
        do {
            let remove = try statement("DELETE FROM sources WHERE region=?"); defer { sqlite3_finalize(remove) }
            try bind(region.code, at: 1,to: remove); guard sqlite3_step(remove) == SQLITE_DONE else { throw DeviceShareError.unavailable }
            let removeRaw = try statement("DELETE FROM raw_sources WHERE region=?"); defer { sqlite3_finalize(removeRaw) }
            try bind(region.code, at: 1,to: removeRaw); guard sqlite3_step(removeRaw) == SQLITE_DONE else { throw DeviceShareError.unavailable }
            let insertRaw = try statement("INSERT OR REPLACE INTO raw_sources(id,region,data) VALUES(?,?,?)"); defer { sqlite3_finalize(insertRaw) }
            for raw in region.records + (region.kaptRecords ?? []) {
                sqlite3_reset(insertRaw); sqlite3_clear_bindings(insertRaw)
                try bind(raw.id,at: 1,to: insertRaw); try bind(region.code,at: 2,to: insertRaw); try bind(DeviceShareCodec.encode(raw),at: 3,to: insertRaw)
                guard sqlite3_step(insertRaw) == SQLITE_DONE else { throw DeviceShareError.unavailable }
            }
            let insert = try statement("INSERT OR REPLACE INTO sources(id,region,name,address,data) VALUES(?,?,?,?,?)"); defer { sqlite3_finalize(insert) }
            for source in HousingConsolidator.sources(region, overrides: edits) {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                try bind(source.id,at: 1,to: insert); try bind(region.code,at: 2,to: insert)
                try bind(source.fields["name"] ?? "",at: 3,to: insert)
                try bind(source.fields.values.joined(separator: " "),at: 4,to: insert)
                try bind(DeviceShareCodec.encode(source),at: 5,to: insert)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw DeviceShareError.unavailable }
            }
            let meta = try statement("INSERT OR REPLACE INTO regions(code,data) VALUES(?,?)"); defer { sqlite3_finalize(meta) }
            try bind(region.code,at: 1,to: meta); try bind(DeviceShareCodec.encode(HousingRegionSummary(region)),at: 2,to: meta)
            guard sqlite3_step(meta) == SQLITE_DONE else { throw DeviceShareError.unavailable }; try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }
    func search(region: String, keyword: String, sourceIDs: Set<String>) throws -> [HousingSource] {
        let s = try statement("SELECT data FROM sources WHERE (?='' OR region=?) AND (?='' OR instr(lower(name),lower(?))>0 OR instr(lower(address),lower(?))>0) ORDER BY name LIMIT 2000")
        defer { sqlite3_finalize(s) }
        for (i,value) in [region,region,keyword,keyword,keyword].enumerated() { try bind(value,at: Int32(i+1),to: s) }
        var records: [String: HousingSource] = [:]; var status = sqlite3_step(s)
        while status == SQLITE_ROW { let value = try JSONDecoder().decode(HousingSource.self,from: Self.blob(s)); records[value.id] = value; status = sqlite3_step(s) }
        guard status == SQLITE_DONE else { throw DeviceShareError.unavailable }
        let selected = try statement("SELECT data FROM raw_sources WHERE id=?"); defer { sqlite3_finalize(selected) }
        for id in sourceIDs where records[id] == nil {
            sqlite3_reset(selected); sqlite3_clear_bindings(selected); try bind(id,at: 1,to: selected)
            if sqlite3_step(selected) == SQLITE_ROW { records[id] = try JSONDecoder().decode(HousingSource.self,from: Self.blob(selected)) }
        }
        return Array(records.values)
    }
    static func search(directory: URL, region: String, keyword: String, sourceIDs: Set<String>) throws -> [HousingSource] {
        try HousingIndex(directory: directory).search(region: region, keyword: keyword, sourceIDs: sourceIDs)
    }
}
