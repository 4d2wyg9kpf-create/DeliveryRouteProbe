import Foundation
import SQLite3

final class KakaoDistanceArchive {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(directory.appendingPathComponent("kakao-distances.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DeviceShareError.unavailable }
        sqlite3_busy_timeout(db,5000)
        try run("PRAGMA journal_mode=WAL")
        try run("CREATE TABLE IF NOT EXISTS distances(id TEXT PRIMARY KEY, queried REAL NOT NULL, data BLOB NOT NULL)")
        try run("CREATE INDEX IF NOT EXISTS distances_queried ON distances(queried)")
    }
    deinit { sqlite3_close(db) }
    private func run(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw DeviceShareError.unavailable } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&s,nil) == SQLITE_OK, let s else { throw DeviceShareError.unavailable }; return s
    }
    func append(_ records: [KakaoDistanceRecord]) throws {
        try run("BEGIN IMMEDIATE")
        do {
            let s = try statement("INSERT OR IGNORE INTO distances(id,queried,data) VALUES(?,?,?)"); defer { sqlite3_finalize(s) }
            for r in records {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                guard sqlite3_bind_text(s,1,r.id,-1,Self.transient) == SQLITE_OK, sqlite3_bind_double(s,2,r.queriedAt.timeIntervalSince1970) == SQLITE_OK else { throw DeviceShareError.unavailable }
                let data = try DeviceShareCodec.encode(r)
                let status = data.withUnsafeBytes { sqlite3_bind_blob(s,3,$0.baseAddress,Int32(data.count),Self.transient) }
                guard status == SQLITE_OK, sqlite3_step(s) == SQLITE_DONE else { throw DeviceShareError.unavailable }
            }
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }
    var count: Int {
        get throws { let s = try statement("SELECT COUNT(*) FROM distances"); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_ROW else { throw DeviceShareError.unavailable }; return Int(sqlite3_column_int64(s,0)) }
    }
    private func read(_ s: OpaquePointer) throws -> KakaoDistanceRecord {
        let count = sqlite3_column_bytes(s,0); guard count > 0, count <= 500_000, let bytes = sqlite3_column_blob(s,0) else { throw DeviceShareError.invalid }
        return try JSONDecoder().decode(KakaoDistanceRecord.self,from: Data(bytes: bytes,count: Int(count)))
    }
    func recent() throws -> [KakaoDistanceRecord] {
        let s = try statement("SELECT data FROM distances ORDER BY queried DESC,id DESC LIMIT 5000"); defer { sqlite3_finalize(s) }
        var records: [KakaoDistanceRecord] = []; var status = sqlite3_step(s)
        while status == SQLITE_ROW { records.append(try read(s)); status = sqlite3_step(s) }
        guard status == SQLITE_DONE else { throw DeviceShareError.unavailable }; return records.reversed()
    }
    func exportCSV(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path,contents: nil)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.write(contentsOf: Data(("\u{FEFF}" + kakaoCSVHeader + "\r\n").utf8))
        let s = try statement("SELECT data FROM distances ORDER BY queried,id"); defer { sqlite3_finalize(s) }
        var status = sqlite3_step(s)
        while status == SQLITE_ROW { try file.write(contentsOf: Data((kakaoCSVRow(try read(s)) + "\r\n").utf8)); status = sqlite3_step(s) }
        guard status == SQLITE_DONE else { throw DeviceShareError.unavailable }
    }
}
