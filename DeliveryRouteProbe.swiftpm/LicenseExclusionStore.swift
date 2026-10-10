import Foundation
import Combine

enum PublicRoadAddress {
    static func buildingAddress(_ address: String) -> String? {
        let normalized = address.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Stop at the road-name building number, before floors, units, building
        // names or a parenthesized neighborhood. Keep subnumbers and '지하'.
        let pattern = #"^(.+?\s[^\s,()]+(?:대로|로|길))\s+(지하\s*)?([0-9]+(?:-[0-9]+)?)(?=$|[\s,(])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let roadRange = Range(match.range(at: 1), in: normalized),
              let numberRange = Range(match.range(at: 3), in: normalized) else { return nil }
        var road = String(normalized[roadRange])
        if road.hasPrefix("대전 ") { road = "대전광역시 " + String(road.dropFirst(3)) }
        let underground = match.range(at: 2).location != NSNotFound ? "지하" : ""
        let numbers = normalized[numberRange].split(separator: "-")
        guard let main = Int(numbers[0]), main > 0 else { return nil }
        var number = String(main)
        if numbers.count == 2 {
            guard let sub = Int(numbers[1]), sub > 0 else { return nil }
            number += "-\(sub)"
        }
        return road + " " + underground + number
    }
    static func buildingKey(_ address: String) -> String? {
        guard let building = buildingAddress(address) else { return nil }
        let parts = building.split(separator: " ")
        guard parts.count == 4, parts[0] == "대전광역시", ["동구", "중구", "서구", "유성구", "대덕구"].contains(String(parts[1])) else { return nil }
        return building.replacingOccurrences(of: " ", with: "")
    }
    static func naverSearchURL(_ address: String) -> URL? {
        guard let building = buildingAddress(address),
              let encoded = building.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) else { return nil }
        return URL(string: "https://map.naver.com/p/search/" + encoded)
    }
}

struct LicenseExcludedAddress: Codable, Identifiable {
    var id: String
    var address: String
}
private struct LicenseExclusionArchive: Codable {
    var version = 1
    var records: [LicenseExcludedAddress] = []
}

@MainActor
final class LicenseExclusionStore: ObservableObject {
    static let shared = LicenseExclusionStore()
    static let services: Set<PublicDataService> = [.restaurants, .cafes, .bakery]
    @Published private(set) var records: [LicenseExcludedAddress] = []
    @Published var errorMessage: String?
    private let writeState: (Data) throws -> Void
    private var writable = true

    convenience init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteProbe", isDirectory: true)
        let file = folder.appendingPathComponent("license-excluded-addresses.json")
        self.init(read: {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try Data(contentsOf: file)
        }, write: { data in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        })
    }
    init(read: () throws -> Data?, write: @escaping (Data) throws -> Void) {
        writeState = write
        do {
            if let data = try read() {
                let archive = try Self.decode(data)
                records = archive.records
            }
        } catch { writable = false; errorMessage = "기존 제외 주소 기록은 보존했습니다. 보관함을 읽지 못해 변경을 차단합니다." }
    }
    private static func decode(_ data: Data) throws -> LicenseExclusionArchive {
        guard data.count <= 1_000_000 else { throw PublicDataFailure.message("제외 주소 보관함이 너무 큽니다.") }
        let archive = try JSONDecoder().decode(LicenseExclusionArchive.self, from: data)
        let keys = archive.records.compactMap { PublicRoadAddress.buildingKey($0.address) }
        guard archive.version == 1, archive.records.count <= 500,
              keys.count == archive.records.count, Set(keys).count == keys.count,
              Set(archive.records.map(\.id)).count == archive.records.count,
              archive.records.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.address.utf8.count <= 1_000 && PublicRoadAddress.buildingAddress($0.address) == $0.address }) else {
            throw PublicDataFailure.message("제외 주소 보관함 형식을 확인하세요.")
        }
        return archive
    }
    func add(_ address: String) throws {
        guard let building = PublicRoadAddress.buildingAddress(address), let key = PublicRoadAddress.buildingKey(building) else {
            throw PublicDataFailure.message("대전의 구·도로명·건물번호가 포함된 주소를 입력하세요. 예: 대전광역시 서구 둔산로 1")
        }
        guard !records.contains(where: { PublicRoadAddress.buildingKey($0.address) == key }) else { throw PublicDataFailure.message("이미 제외 목록에 있는 건물 주소입니다.") }
        guard records.count < 500 else { throw PublicDataFailure.message("제외 주소는 최대 500개까지 저장합니다.") }
        try commit(records + [LicenseExcludedAddress(id: UUID().uuidString, address: building)])
    }
    func remove(_ id: String) throws { try commit(records.filter { $0.id != id }) }
    func excludes(_ business: PublicLicense) -> Bool {
        guard Self.services.contains(business.service), let key = PublicRoadAddress.buildingKey(business.address) else { return false }
        return records.contains { PublicRoadAddress.buildingKey($0.address) == key }
    }
    private func commit(_ next: [LicenseExcludedAddress]) throws {
        guard writable else { throw PublicDataFailure.message("제외 주소 보관함 오류를 해결한 뒤 변경하세요. 기존 기록은 보존합니다.") }
        let data = try JSONEncoder().encode(LicenseExclusionArchive(records: next))
        _ = try Self.decode(data)
        try writeState(data)
        records = next; errorMessage = nil
    }
}
