import Foundation
import CryptoKit

enum DeviceShareError: Error, LocalizedError {
    case invalid, unavailable, newerVersion
    var errorDescription: String? {
        switch self {
        case .invalid: return "공유 기록을 확인하지 못했습니다. 기존 기록을 보존하고 동기화를 보류합니다."
        case .unavailable: return "공유 폴더를 열지 못했습니다. 파일 앱의 다운로드 상태를 확인하거나 폴더를 다시 선택하세요."
        case .newerVersion: return "다른 기기의 앱이 더 새로운 공유 형식을 사용합니다. 앱을 업데이트하세요."
        }
    }
}

enum DeviceShareCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= 250_000_000 else { throw DeviceShareError.invalid }
        return try JSONDecoder().decode(type, from: data)
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func key(_ text: String) -> String { digest(Data(text.utf8)) }
    static func addressIdentity(_ address: String) -> String {
        var value = address.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = ["대전": "대전광역시", "서울": "서울특별시", "부산": "부산광역시", "대구": "대구광역시", "인천": "인천광역시", "광주": "광주광역시", "울산": "울산광역시", "세종": "세종특별자치시", "경기": "경기도", "충남": "충청남도", "충북": "충청북도", "경남": "경상남도", "경북": "경상북도", "전남": "전라남도", "전북": "전북특별자치도", "강원": "강원특별자치도", "제주": "제주특별자치도"]
        for (alias, full) in aliases where value.hasPrefix(alias + " ") { value = full + String(value.dropFirst(alias.count)); break }
        if let range = value.range(of: #"^.+?\s[^\s,()]+(?:대로|로|길)\s+(?:지하\s*)?[0-9]+(?:-[0-9]+)?(?=$|[\s,(])"#, options: .regularExpression) { value = String(value[range]) }
        return value.replacingOccurrences(of: " ", with: "")
    }
    static func validateKey(_ value: String, max: Int = 512) throws {
        guard !value.isEmpty, value.utf8.count <= max,
              !value.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }) else { throw DeviceShareError.invalid }
    }
}

struct DeviceShareStamp: Codable, Equatable, Comparable {
    var counter: Int
    var device: String
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.device < rhs.device : lhs.counter < rhs.counter
    }
}
struct DeviceShareRecord: Codable, Equatable {
    var stamp: DeviceShareStamp
    var value: Data? // A durable tombstone prevents offline devices resurrecting a deletion.
}
struct DeviceShareFloor: Codable, Equatable {
    var stamp: DeviceShareStamp
    var used: Int
    var basis: [String: Int]
}
struct DeviceShareUsageObservation: Codable, Equatable {
    var domain: String
    var account: String
    var period: String
    var slot: String
    var used: Int
    var limit: Int
    var blocked: Bool
    var trustedMillis: Double
    var resetMillis: Double = 0
    var id: String { [domain, account, period, slot].joined(separator: "|") }
}
struct DeviceShareUsage: Codable, Equatable {
    var observation: DeviceShareUsageObservation
    var components: [String: Int] = [:]
    var floors: [String: DeviceShareFloor] = [:]
    var total: Int {
        let sum = components.values.reduce(0, +)
        return floors.values.reduce(sum) { result, floor in
            let subsequent = components.reduce(0) { $0 + max(0, $1.value - (floor.basis[$1.key] ?? 0)) }
            return max(result, floor.used + subsequent)
        }
    }
    mutating func merge(_ other: Self) throws {
        guard observation.id == other.observation.id else { throw DeviceShareError.invalid }
        for (device, count) in other.components { components[device] = max(components[device] ?? 0, count) }
        for (device, floor) in other.floors {
            if let current = floors[device], current.stamp == floor.stamp, current != floor { throw DeviceShareError.invalid }
            if floors[device] == nil || floors[device]!.stamp < floor.stamp { floors[device] = floor }
        }
        observation.blocked = observation.blocked || other.observation.blocked
        observation.used = max(observation.used, other.observation.used)
        observation.limit = min(observation.limit, other.observation.limit)
        observation.trustedMillis = max(observation.trustedMillis, other.observation.trustedMillis)
        observation.resetMillis = max(observation.resetMillis, other.observation.resetMillis)
    }
}
struct DeviceShareSnapshot {
    var values: [String: Data] = [:]
    var usage: [DeviceShareUsageObservation] = []
    mutating func append(_ other: Self) {
        values.merge(other.values) { _, incoming in incoming }; usage.append(contentsOf: other.usage)
    }
}

// Each device writes its own replica file. No two devices overwrite one shared file.
// Records use logical revisions; request counters are a grow-only component per device.
struct DeviceShareReplica: Codable, Equatable {
    var version = 1
    var deviceID: String
    var counter = 0
    var records: [String: DeviceShareRecord] = [:]
    var usage: [String: DeviceShareUsage] = [:]
    mutating func stamp() throws -> DeviceShareStamp {
        guard counter < 1_000_000_000_000 else { throw DeviceShareError.invalid }
        counter += 1
        return DeviceShareStamp(counter: counter, device: deviceID)
    }
    mutating func capture(_ snapshot: DeviceShareSnapshot, observed: inout [String: Data], reservations: [String] = []) throws {
        for key in Set(observed.keys).union(snapshot.values.keys).sorted() where observed[key] != snapshot.values[key] {
            records[key] = DeviceShareRecord(stamp: try stamp(), value: snapshot.values[key])
        }
        observed = snapshot.values
        let deltas = Dictionary(reservations.map { ($0, 1) }, uniquingKeysWith: +)
        for item in snapshot.usage {
            let isNew = usage[item.id] == nil
            var bucket = usage[item.id] ?? DeviceShareUsage(observation: item)
            if isNew {
                bucket.components[deviceID] = item.used // Migrate pre-sharing, device-local usage once.
            } else if let delta = deltas[item.id] {
                bucket.components[deviceID] = (bucket.components[deviceID] ?? 0) + delta
            }
            if item.used > bucket.total {
                // An entered/provider total is a floor, not a second batch of requests.
                // Its basis makes later requests add to that total without double counting.
                bucket.floors[deviceID] = DeviceShareFloor(stamp: try stamp(), used: item.used, basis: bucket.components)
            }
            bucket.observation.blocked = bucket.observation.blocked || item.blocked
            bucket.observation.trustedMillis = max(bucket.observation.trustedMillis, item.trustedMillis)
            bucket.observation.resetMillis = max(bucket.observation.resetMillis, item.resetMillis)
            usage[item.id] = bucket
        }
        try validate()
    }
    mutating func merge(_ other: Self) throws {
        try other.validate()
        counter = max(counter, other.counter)
        for (key, record) in other.records {
            if let current = records[key], current.stamp == record.stamp, current != record { throw DeviceShareError.invalid }
            if records[key] == nil || records[key]!.stamp < record.stamp { records[key] = record }
        }
        for (key, otherBucket) in other.usage {
            if var bucket = usage[key] { try bucket.merge(otherBucket); usage[key] = bucket }
            else { usage[key] = otherBucket }
        }
        try validate()
    }
    func validate() throws {
        guard version == 1 else { throw DeviceShareError.newerVersion }
        guard UUID(uuidString: deviceID) != nil, (0...1_000_000_000_000).contains(counter), records.count <= 250_000, usage.count <= 250_000 else { throw DeviceShareError.invalid }
        func validStamp(_ stamp: DeviceShareStamp) -> Bool {
            UUID(uuidString: stamp.device) != nil && (1...max(1, counter)).contains(stamp.counter)
        }
        for (key, record) in records {
            guard key.utf8.count <= 1_000, ["setting/", "customer/", "excluded/", "site/", "housing/"].contains(where: { key.hasPrefix($0) }),
                  validStamp(record.stamp), (record.value?.count ?? 0) <= 500_000 else { throw DeviceShareError.invalid }
        }
        for (key, bucket) in usage {
            let item = bucket.observation
            guard key == item.id, ["tmap", "naver", "public", "kakao"].contains(item.domain), item.account.utf8.count <= 200,
                  item.period.range(of: #"^\d{4}-\d{2}(?:-\d{2})?$"#, options: .regularExpression) != nil,
                  item.slot.utf8.count <= 100, (0...10_000_000).contains(item.used), (1...10_000_000).contains(item.limit),
                  item.trustedMillis.isFinite, item.trustedMillis >= 0, item.resetMillis.isFinite, item.resetMillis >= 0,
                  bucket.components.count <= 100, bucket.floors.count <= 100,
                  bucket.components.allSatisfy({ UUID(uuidString: $0.key) != nil && (0...10_000_000).contains($0.value) }),
                  bucket.floors.allSatisfy({ UUID(uuidString: $0.key) != nil && validStamp($0.value.stamp) && (0...10_000_000).contains($0.value.used) && $0.value.basis.count <= 100 && $0.value.basis.allSatisfy({ UUID(uuidString: $0.key) != nil && (0...10_000_000).contains($0.value) }) }),
                  bucket.total <= 1_000_000_000 else { throw DeviceShareError.invalid }
        }
    }
    func value<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try records[key]?.value.map { try DeviceShareCodec.decode(type, $0) }
    }
    func usages(_ domain: String) -> [DeviceShareUsage] {
        usage.values.filter { $0.observation.domain == domain }.sorted { $0.observation.id < $1.observation.id }
    }
    func encoded() throws -> Data {
        try validate()
        let payload = try DeviceShareCodec.encode(self)
        return try DeviceShareCodec.encode(DeviceShareEnvelope(version: 1, payload: payload, sha256: DeviceShareCodec.digest(payload)))
    }
    static func decoded(_ data: Data) throws -> Self {
        let envelope = try DeviceShareCodec.decode(DeviceShareEnvelope.self, data)
        guard envelope.version == 1 else { throw DeviceShareError.newerVersion }
        guard DeviceShareCodec.digest(envelope.payload) == envelope.sha256 else { throw DeviceShareError.invalid }
        let replica = try DeviceShareCodec.decode(Self.self, envelope.payload); try replica.validate(); return replica
    }
}
private struct DeviceShareEnvelope: Codable {
    var version: Int
    var payload: Data
    var sha256: String
}
struct DeviceShareCheckpoint: Codable {
    var version = 1
    var replica: DeviceShareReplica
    var observed: [String: Data] = [:]
}

// Injected by the app root. Native store tests can run without a file picker or iCloud.
@MainActor
enum DeviceShareHooks {
    static var didChange: (([String]) throws -> Void)?
    static var beforeRequest: (() async throws -> Void)?
    static func changed(reservations: [String] = []) throws { try didChange?(reservations) }
    static func prepareRequest() async throws { try await beforeRequest?() }
}

struct DeviceShareTMapSettings: Codable { var appKey: String; var freeConfirmed: Bool }
struct DeviceShareNaverSearch: Codable { var id: String; var secret: String; var provider: String; var freeConfirmed: Bool }
struct DeviceShareNaverMaps: Codable { var id: String; var secret: String; var freeConfirmed: Bool }
struct DeviceSharePublicSettings: Codable { var key: String; var approved: [String]; var limits: [String: Int] }
