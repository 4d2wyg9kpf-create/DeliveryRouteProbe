import Foundation
import CryptoKit

enum APICredentialStorageError: Error, LocalizedError {
    case invalid, conflict, unavailable, notLoaded
    var errorDescription: String? {
        switch self {
        case .invalid: return "키·사용량 저장 기록이 손상되어 요청을 차단했습니다."
        case .conflict: return "키·사용량 저장 기록이 서로 달라 요청을 차단했습니다."
        case .unavailable: return "키·사용량 저장 공간을 열지 못했습니다. 기기를 잠금 해제한 뒤 다시 실행해 주세요."
        case .notLoaded: return "기존 키·사용량 기록을 먼저 복구해야 합니다."
        }
    }
}

// The same Keychain identifiers are retained. A protected app-container copy also
// survives in-place updates when a signing change makes the old Keychain group
// inaccessible. Both copies contain the complete settings AND usage ledger.
@MainActor
final class APICredentialArchive {
    private struct Metadata: Codable {
        var version: Int
        var revision: Int
        var sha256: String
    }
    private struct Record {
        var payload: Data
        var revision: Int
        var digest: String
    }
    private static let metadataKey = "_deliveryPersistence"
    private static let maxBytes = 2_000_000
    private static let maxRevision = 9_007_199_254_740_990
    private let readPrimary: () throws -> Data?
    private let writePrimary: (Data) throws -> Void
    private let readProtected: () throws -> Data?
    private let writeProtected: (Data) throws -> Void
    private let validate: (Data) throws -> Void
    private var revision = 0
    private var loaded = false

    init(readPrimary: @escaping () throws -> Data?, writePrimary: @escaping (Data) throws -> Void,
         readProtected: @escaping () throws -> Data?, writeProtected: @escaping (Data) throws -> Void,
         validate: @escaping (Data) throws -> Void) {
        self.readPrimary = readPrimary; self.writePrimary = writePrimary
        self.readProtected = readProtected; self.writeProtected = writeProtected
        self.validate = validate
    }

    func read() throws -> Data? {
        loaded = false
        var primary: Data?
        var primaryUnavailable = false
        do { primary = try readPrimary() } catch { primaryUnavailable = true }
        // An unreadable protected file may contain a newer reservation. Never
        // overwrite it with an older Keychain value or reset the quota to zero.
        let protected: Data?
        do { protected = try readProtected() } catch { throw APICredentialStorageError.unavailable }
        let first = try primary.map { try unpack($0) }
        let second = try protected.map { try unpack($0) }
        if let first, let second, first.revision == second.revision, first.digest != second.digest {
            throw APICredentialStorageError.conflict
        }
        guard let chosen = [first, second].compactMap({ $0 }).max(by: { $0.revision < $1.revision }) else {
            guard !primaryUnavailable else { throw APICredentialStorageError.unavailable }
            revision = 0; loaded = true
            return nil
        }
        let nextRevision = max(1, chosen.revision)
        let encoded = try pack(chosen.payload, revision: nextRevision)
        if second?.revision != nextRevision || second?.digest != chosen.digest {
            try writeProtected(encoded) // Migrate old Keychain-only installs before any request.
        }
        if first?.revision != nextRevision || first?.digest != chosen.digest {
            try? writePrimary(encoded) // The protected copy already holds the latest state.
        }
        revision = nextRevision; loaded = true
        return chosen.payload
    }

    func write(_ data: Data) throws {
        guard loaded else { throw APICredentialStorageError.notLoaded }
        guard revision < Self.maxRevision else { throw APICredentialStorageError.invalid }
        let encoded = try pack(data, revision: revision + 1)
        // Persist first, then allow the store to publish/dispatch. If this fails,
        // no billable request can leave the app. Keychain failure alone is safe
        // because the newer protected copy is already durable.
        try writeProtected(encoded)
        revision += 1
        try? writePrimary(encoded)
    }

    private func unpack(_ data: Data) throws -> Record {
        guard data.count <= Self.maxBytes,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APICredentialStorageError.invalid
        }
        let metadata = object.removeValue(forKey: Self.metadataKey)
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try validate(payload)
        let digest = Self.digest(payload)
        if let metadata {
            let decoded = try JSONDecoder().decode(Metadata.self, from: JSONSerialization.data(withJSONObject: metadata))
            guard decoded.version == 1, (1...Self.maxRevision).contains(decoded.revision), decoded.sha256 == digest else {
                throw APICredentialStorageError.invalid
            }
            return Record(payload: payload, revision: decoded.revision, digest: digest)
        }
        return Record(payload: payload, revision: 0, digest: digest)
    }

    private func pack(_ data: Data, revision: Int) throws -> Data {
        guard data.count <= Self.maxBytes,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object[Self.metadataKey] == nil else { throw APICredentialStorageError.invalid }
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try validate(payload)
        object[Self.metadataKey] = ["version": 1, "revision": revision, "sha256": Self.digest(payload)]
        let result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard result.count <= Self.maxBytes else { throw APICredentialStorageError.invalid }
        // Metadata is an extra top-level field: older decoders can still read
        // the unchanged state format instead of encountering a new envelope.
        return result
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct APIProtectedStateFile {
    enum Kind: String { case tmap, naverAPI = "naver-api" }
    let url: URL
    init(_ kind: Kind, directory: URL? = nil) throws {
        let parent = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DeliveryRouteSecureState", isDirectory: true)
        url = parent.appendingPathComponent(kind.rawValue + ".state", isDirectory: false)
    }
    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let count = values.fileSize, count <= 2_000_000 else { throw APICredentialStorageError.invalid }
        return try Data(contentsOf: url)
    }
    func write(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
