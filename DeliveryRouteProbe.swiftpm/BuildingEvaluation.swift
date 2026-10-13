import Foundation

enum BuildingEvaluationError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

// Addresses identify a reference candidate; individual buildings remain distinct
// beneath that address. Floors and units never become separate buildings.
enum BuildingAddress {
    static func clean(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func road(_ value: String) -> String? {
        let value = clean(value)
        guard let expression = try? NSRegularExpression(pattern: #"^(.+?\s[^\s,;()/]+(?:로|길)\s+\d+(?:-\d+)?)(?=$|[\s,(])"#),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    static func key(_ value: String) -> String? {
        guard let address = road(value) else { return nil }
        var words = address.split(separator: " ").map(String.init)
        let aliases = ["서울":"서울특별시", "부산":"부산광역시", "대구":"대구광역시", "인천":"인천광역시", "광주":"광주광역시", "대전":"대전광역시", "울산":"울산광역시", "세종":"세종특별자치시", "경기":"경기도", "강원":"강원특별자치도", "강원도":"강원특별자치도", "충북":"충청북도", "충남":"충청남도", "전북":"전북특별자치도", "전라북도":"전북특별자치도", "전남":"전라남도", "경북":"경상북도", "경남":"경상남도", "제주":"제주특별자치도", "제주도":"제주특별자치도"]
        if let first = words.first, let canonical = aliases[first] { words[0] = canonical }
        if let last = words.last {
            let raw = last.split(separator:"-"), values = raw.compactMap { Int($0) }
            guard values.count == raw.count, !values.isEmpty, values.allSatisfy({ $0 >= 0 }) else { return nil }
            words[words.count - 1] = values.map(String.init).joined(separator:"-")
        }
        return words.joined(separator: " ")
    }
    static func split(_ value: String) -> [String] {
        Array(Set(parts(value).compactMap(road))).sorted()
    }
    static func allPartsValid(_ value: String) -> Bool {
        let parts = parts(value)
        return !parts.isEmpty && parts.allSatisfy { part in
            guard road(part) != nil, let expression = try? NSRegularExpression(pattern:#"[^\s,;()/]+(?:로|길)\s+\d+(?:-\d+)?"#) else { return false }
            return expression.numberOfMatches(in:part,range:NSRange(part.startIndex...,in:part)) == 1
        }
    }
    private static func parts(_ value: String) -> [String] {
        // Commas inside parenthesized locality/building names aren't separators.
        var parts: [String] = [], current = "", depth = 0
        for character in value {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if depth == 0 && "\n\r;,/|".contains(character) { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        return parts.map(clean).filter { !$0.isEmpty }
    }
    static func dongKey(_ value: String) -> String {
        var value = clean(value).replacingOccurrences(of: " ", with: "").lowercased()
        if value.hasSuffix("동") { value.removeLast() }
        if let number = Int(value) { return String(number) }
        return value
    }
    static func dongLess(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = dongKey(lhs).compare(dongKey(rhs), options: [.numeric, .caseInsensitive, .widthInsensitive], range: nil, locale: Locale(identifier: "ko_KR"))
        return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
    }
}

struct EvaluationBuilding: Codable, Equatable, Identifiable {
    var id: String
    var roadAddress: String
    var name: String
    var dongName: String
    var fields: [String: String]
    var fetchedAt: Date
    var roadKey: String { BuildingAddress.key(roadAddress) ?? "" }
    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 200, !roadKey.isEmpty, dongName.utf8.count <= 200,
              name.utf8.count <= 500, fields.count <= 100, fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) else {
            throw BuildingEvaluationError.message("건축물대장 건물 식별정보와 주소를 확인하세요.")
        }
    }
}

enum BuildingChoice: String, Codable { case single, firstDong, specifiedDong }
struct BuildingSelection: Codable, Equatable {
    var building: EvaluationBuilding
    var choice: BuildingChoice
    var entranceSource: String
    var entranceID: String
    var longitude: Double
    var latitude: Double
    var defaultForAddress: Bool? = nil
    // A shared road address alone must never merge 101 and 102.
    var identity: String { building.roadKey + "|" + building.id }
    var isDefaultForAddress: Bool { defaultForAddress ?? (choice != .specifiedDong) }
    func validate() throws {
        try building.validate()
        guard !entranceSource.isEmpty, entranceSource.utf8.count <= 2_000,
              !entranceID.isEmpty, entranceID.utf8.count <= 500,
              longitude.isFinite, latitude.isFinite, (124...132).contains(longitude), (32...40).contains(latitude) else {
            throw BuildingEvaluationError.message("선택한 건물의 출입구와 좌표 출처를 확인하세요.")
        }
    }
}

enum BuildingSelector {
    static func choose(_ buildings: [EvaluationBuilding], roadAddress: String, dong: String = "", expectedDongNames: [String] = []) throws -> (EvaluationBuilding, BuildingChoice) {
        guard let key = BuildingAddress.key(roadAddress) else { throw BuildingEvaluationError.message("정확한 도로명주소를 입력하세요.") }
        let matching = buildings.filter { $0.roadKey == key }
        guard !matching.isEmpty else { throw BuildingEvaluationError.message("해당 도로명주소의 건축물대장이 없습니다.") }
        guard Set(matching.map(\.id)).count == matching.count else { throw BuildingEvaluationError.message("건축물대장 식별자가 중복되었습니다.") }
        let requested = BuildingAddress.dongKey(dong)
        if !requested.isEmpty {
            let found = matching.filter { BuildingAddress.dongKey($0.dongName) == requested }
            guard found.count == 1 else { throw BuildingEvaluationError.message("지정한 동이 없거나 동 명칭이 중복됩니다. 해당 건물을 직접 확인하세요.") }
            return (found[0], .specifiedDong)
        }
        let expected = Set(expectedDongNames.map(BuildingAddress.dongKey).filter { !$0.isEmpty })
        let available = Set(matching.map { BuildingAddress.dongKey($0.dongName) })
        guard expected.isSubset(of:available) else { throw BuildingEvaluationError.message("주소에 등록된 동 중 일부의 대장이 미확인되어 첫 동을 확정하지 못했습니다. 동을 직접 지정하거나 누락된 대장을 확인하세요.") }
        if matching.count == 1 { return (matching[0], .single) }
        guard matching.allSatisfy({ !BuildingAddress.dongKey($0.dongName).isEmpty }),
              Set(matching.map { BuildingAddress.dongKey($0.dongName) }).count == matching.count else {
            throw BuildingEvaluationError.message("여러 건물의 동 명칭이 비어 있거나 중복되어 첫 동을 확정하지 못했습니다.")
        }
        let first = matching.sorted { BuildingAddress.dongLess($0.dongName, $1.dongName) }[0]
        return (first, .firstDong)
    }
}

enum BuildingFactSource: String, Codable { case registry, realty, kapt }
enum BuildingFactScope: String, Codable { case building, complex }
struct BuildingFact: Codable, Equatable {
    var value: String
    var source: BuildingFactSource
    var scope: BuildingFactScope
}
enum BuildingFacts {
    static func consensus(_ sources: [[String:String]]) -> [String:String] {
        var result: [String:String] = [:]
        for key in Set(sources.flatMap { $0.keys }) {
            let values = Set(sources.compactMap { blank($0[key]) ? nil : $0[key] })
            if values.count == 1 { result[key] = values.first }
        }
        return result
    }
    static func blank(_ value: String?) -> Bool {
        guard let value else { return true }
        return ["", "-", "미확인", "null"].contains(BuildingAddress.clean(value).lowercased())
    }
    static func resolve(registry: [String: String], realty: [String: String], kapt: [String: String], apartment: Bool) -> [String: BuildingFact] {
        var result: [String: BuildingFact] = [:]
        for (key, value) in registry where !blank(value) { result[key] = BuildingFact(value: value, source: .registry, scope: .building) }
        guard apartment else { return result }
        for (source, fields) in [(BuildingFactSource.realty, realty), (.kapt, kapt)] {
            for (key, value) in fields where result[key] == nil && !blank(value) {
                result[key] = BuildingFact(value: value, source: source, scope: .complex)
            }
        }
        return result
    }
}

struct KaptReferenceRecord: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var roadAddresses: [String]
    var fields: [String: String] = [:]
    var fetchedAt: Date?
}
struct KaptReferenceAddress: Codable, Equatable, Identifiable {
    var roadAddress: String
    var kaptIDs: [String]
    var names: [String]
    var id: String { BuildingAddress.key(roadAddress) ?? "" }
}
struct KaptReferenceCatalog: Codable, Equatable {
    var addresses: [KaptReferenceAddress]
    var missingAddressIDs: [String]
    var unresolvedIDs: [String]
    var duplicateAddressCount: Int
    var complete: Bool { unresolvedIDs.isEmpty }
    static func build(_ records: [KaptReferenceRecord]) throws -> Self {
        guard records.count <= 100_000, Set(records.map(\.id)).count == records.count else {
            throw BuildingEvaluationError.message("K-apt 원본 단지 코드가 중복되거나 목록이 너무 큽니다.")
        }
        var grouped: [String: KaptReferenceAddress] = [:], empty: [String] = [], unresolved: [String] = [], duplicates = 0
        for record in records.sorted(by: { $0.id < $1.id }) {
            guard record.fetchedAt != nil else { unresolved.append(record.id); continue }
            let nonempty = record.roadAddresses.filter { !BuildingFacts.blank($0) }
            guard !nonempty.isEmpty else { empty.append(record.id); continue }
            guard nonempty.allSatisfy(BuildingAddress.allPartsValid) else { unresolved.append(record.id); continue }
            let roads = nonempty.flatMap(BuildingAddress.split)
            guard !roads.isEmpty else { unresolved.append(record.id); continue }
            var seen = Set<String>()
            for road in roads {
                guard let key = BuildingAddress.key(road), seen.insert(key).inserted else { continue }
                if var prior = grouped[key] {
                    duplicates += 1; prior.kaptIDs.append(record.id); prior.names = Array(Set(prior.names + [record.name])).sorted(); grouped[key] = prior
                } else { grouped[key] = KaptReferenceAddress(roadAddress: road, kaptIDs: [record.id], names: [record.name]) }
            }
        }
        return Self(addresses: grouped.values.sorted { $0.id < $1.id }, missingAddressIDs: empty.sorted(), unresolvedIDs: unresolved.sorted(), duplicateAddressCount: duplicates)
    }
}
