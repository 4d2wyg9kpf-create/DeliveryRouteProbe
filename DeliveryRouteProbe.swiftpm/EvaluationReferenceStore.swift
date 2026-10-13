import Foundation
import Combine

struct EvaluationConfiguration: Codable, Equatable {
    var conditions = EvaluationConditions()
    var criteria: [EvaluationCriterion] = []
    var activeReferenceID: String?
    func validate() throws { try conditions.validate(); try EvaluationReference.validateCriteria(criteria) }
}
struct EvaluationArchive: Codable, Equatable {
    var version = 1
    var configuration = EvaluationConfiguration()
    var sites: [String: EvaluationSiteRecord] = [:]
    var references: [EvaluationReference] = []
    func validate() throws {
        guard version == 1, sites.count <= 5_000, references.count <= 50,
              Set(references.map(\.id)).count == references.count else { throw EvaluationFailure.message("평가 기준 보관함 형식을 확인하세요.") }
        try configuration.validate()
        for (key, record) in sites { try record.validate(); guard key == record.site.id else { throw DeviceShareError.invalid } }
        for reference in references { try reference.validate() }
        guard configuration.activeReferenceID.map({ id in references.contains { $0.id == id } }) ?? true else { throw DeviceShareError.invalid }
    }
}

@MainActor
final class EvaluationReferenceStore: ObservableObject {
    static let shared = EvaluationReferenceStore()
    @Published private(set) var archive = EvaluationArchive()
    @Published var errorMessage: String?
    private let writeState: (Data) throws -> Void
    private var writable = true
    private var initialized = false
    private var sharedReferences: [String: [String: Data]] = [:]
    var active: EvaluationReference? { archive.references.first { $0.id == archive.configuration.activeReferenceID } }
    var standardCount: Int { archive.sites.values.filter { $0.standardWeight != nil }.count }

    convenience init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteProbe", isDirectory: true)
        let file = folder.appendingPathComponent("evaluation-references.json")
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
                guard data.count <= 25_000_000 else { throw DeviceShareError.invalid }
                let value = try JSONDecoder().decode(EvaluationArchive.self, from: data)
                try value.validate(); archive = value; initialized = true
            }
        } catch { writable = false; errorMessage = "기존 평가 기준과 원자료를 보존했습니다. 보관함을 읽지 못해 변경을 보류합니다." }
    }

    func setStandard(_ site: EvaluationSite, weight: Double?) throws {
        try site.validate()
        var next = archive
        var record = next.sites[site.id] ?? EvaluationSiteRecord(site: site)
        record.site = site; record.standardWeight = weight; try record.validate()
        next.sites[site.id] = record
        guard next.sites.count <= 5_000 else { throw EvaluationFailure.message("평가 원자료는 최대 5,000곳까지 보관합니다.") }
        try commit(next)
    }
    func removeMissingStandard(_ id: String) throws {
        var next = archive; next.sites[id]?.standardWeight = nil; try commit(next)
    }
    func saveCriterion(_ value: EvaluationCriterion) throws {
        try value.validate()
        var next = archive, criterion = value
        if let index = next.configuration.criteria.firstIndex(where: { $0.id == criterion.id }) {
            let old = next.configuration.criteria[index]
            criterion.revision = old.revision
            if criterion == old { return }
            criterion.revision = UUID().uuidString
            next.configuration.criteria[index] = criterion
        } else { next.configuration.criteria.append(criterion) }
        try next.configuration.validate(); try commit(next)
    }
    func removeCriterion(_ id: String) throws {
        var next = archive; next.configuration.criteria.removeAll { $0.id == id }; try commit(next)
    }
    func saveConditions(departure: Date, description: String) throws {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard departure != archive.configuration.conditions.departure || description != archive.configuration.conditions.description else { return }
        var next = archive
        next.configuration.conditions = EvaluationConditions(departure: departure, description: description)
        try next.configuration.validate(); try commit(next)
    }
    func saveObservations(site: EvaluationSite, criteria: [EvaluationCriterion], conditions: EvaluationConditions,
                          values: [String: Double], source: String, now: Date = Date()) throws {
        try site.validate(); try conditions.validate(); try EvaluationReference.validateCriteria(criteria)
        guard Set(values.keys).isSubset(of: Set(criteria.map(\.id))) else { throw DeviceShareError.invalid }
        var next = archive
        var record = next.sites[site.id] ?? EvaluationSiteRecord(site: site)
        record.site = site
        for criterion in criteria {
            let key = conditions.id + "/" + criterion.revision
            if let value = values[criterion.id] {
                let observation = EvaluationObservation(conditionsID: conditions.id, criterionID: criterion.id,
                    criterionRevision: criterion.revision, value: value, longitude: site.longitude, latitude: site.latitude,
                    observedAt: now, source: source.trimmingCharacters(in: .whitespacesAndNewlines))
                try observation.validate(); record.observations[key] = observation
            } else { record.observations.removeValue(forKey: key) }
        }
        try record.validate(); next.sites[site.id] = record
        guard next.sites.count <= 5_000 else { throw EvaluationFailure.message("평가 원자료는 최대 5,000곳까지 보관합니다.") }
        try commit(next)
    }
    func preview(title: String, sites: [EvaluationSite]) throws -> EvaluationReference {
        try EvaluationReference.freeze(title: title, conditions: archive.configuration.conditions,
            criteria: archive.configuration.criteria, sites: sites, records: archive.sites)
    }
    func confirm(_ reference: EvaluationReference) throws {
        guard archive.references.count < 50, !archive.references.contains(where: { $0.id == reference.id }) else { throw EvaluationFailure.message("기준 버전은 최대 50개까지 보관합니다.") }
        try reference.validate()
        var next = archive; next.references.append(reference); next.configuration.activeReferenceID = reference.id
        try commit(next)
    }
    func activate(_ id: String) throws {
        guard archive.references.contains(where: { $0.id == id }) else { throw DeviceShareError.invalid }
        var next = archive; next.configuration.activeReferenceID = id; try commit(next)
    }
    func result(site: EvaluationSite, reference: EvaluationReference) throws -> EvaluationResult {
        try reference.evaluate(site: site, record: archive.sites[site.id])
    }
    func currentResult(site: EvaluationSite) throws -> EvaluationResult {
        guard let active else { throw EvaluationFailure.message("평가 기준을 먼저 확정하세요.") }
        return try result(site: site, reference: active)
    }
    func needsReferenceUpdate(sites: [EvaluationSite]) -> Bool {
        guard let active else { return false }
        guard archive.configuration.criteria == active.criteria, archive.configuration.conditions == active.conditions else { return true }
        let selected = archive.sites.values.filter { $0.standardWeight != nil }
        guard Set(selected.map { $0.site.id }) == Set(active.standards.map { $0.site.id }) else { return true }
        let available = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for standard in active.standards {
            guard let current = available[standard.site.id], let record = archive.sites[standard.site.id],
                  record.standardWeight == standard.weight,
                  current.longitude == standard.site.longitude, current.latitude == standard.site.latitude else { return true }
            for criterion in active.criteria {
                guard record.value(criterion, conditions: active.conditions, site: current) == standard.values[criterion.id] else { return true }
            }
        }
        return false
    }
    private func commit(_ next: EvaluationArchive) throws {
        guard writable else { throw EvaluationFailure.message("기존 보관함 오류를 해결한 뒤 평가 기준을 변경하세요.") }
        let data = try DeviceShareCodec.encode(next)
        guard data.count <= 25_000_000 else { throw EvaluationFailure.message("평가 기준 보관함이 너무 큽니다. 원자료를 백업하세요.") }
        try writeState(data)
        archive = next; initialized = true; errorMessage = nil
        try DeviceShareHooks.changed()
    }
}

private struct EvaluationReferenceHeader: Codable {
    var id: String
    var digest: String
    var parts: Int
}
extension EvaluationReferenceStore {
    // Immutable snapshots may exceed one sharing record's 500 KB limit.
    // Store checksummed pieces under their unique version ID; never replace a version in place.
    func sharingSnapshot() throws -> DeviceShareSnapshot {
        guard writable else { throw DeviceShareError.unavailable }
        var result = DeviceShareSnapshot()
        if initialized { result.values["setting/evaluation/configuration"] = try DeviceShareCodec.encode(archive.configuration) }
        for record in archive.sites.values {
            result.values["setting/evaluation/site/" + DeviceShareCodec.key(record.site.id)] = try DeviceShareCodec.encode(record)
        }
        for reference in archive.references {
            if sharedReferences[reference.id] == nil {
                let data = try DeviceShareCodec.encode(reference), prefix = "setting/evaluation/reference/" + reference.id
                let count = (data.count + 299_999) / 300_000
                var parts: [String: Data] = [:]
                for index in 0..<count {
                    let start = index * 300_000, end = min(start + 300_000, data.count)
                    parts[prefix + "/part/\(index)"] = try DeviceShareCodec.encode(data.subdata(in: start..<end))
                }
                parts[prefix + "/header"] = try DeviceShareCodec.encode(EvaluationReferenceHeader(id: reference.id, digest: DeviceShareCodec.digest(data), parts: count))
                sharedReferences[reference.id] = parts
            }
            result.values.merge(sharedReferences[reference.id]!) { _, value in value }
        }
        guard result.values.values.allSatisfy({ $0.count <= 500_000 }) else { throw DeviceShareError.invalid }
        return result
    }
    func applySharing(_ replica: DeviceShareReplica) throws {
        guard writable else { throw DeviceShareError.unavailable }
        guard replica.records.keys.contains(where: { $0.hasPrefix("setting/evaluation/") }) else { return }
        var next = archive
        if let configuration = try replica.value("setting/evaluation/configuration", as: EvaluationConfiguration.self) {
            try configuration.validate(); next.configuration = configuration
        }
        next.sites = [:]
        for (key, entry) in replica.records where key.hasPrefix("setting/evaluation/site/") {
            guard let data = entry.value else { continue }
            let record = try DeviceShareCodec.decode(EvaluationSiteRecord.self, data)
            try record.validate()
            guard key == "setting/evaluation/site/" + DeviceShareCodec.key(record.site.id) else { throw DeviceShareError.invalid }
            next.sites[record.site.id] = record
        }
        for (key, entry) in replica.records where key.hasPrefix("setting/evaluation/reference/") && key.hasSuffix("/header") {
            guard let data = entry.value else { continue }
            let header = try DeviceShareCodec.decode(EvaluationReferenceHeader.self, data)
            let prefix = "setting/evaluation/reference/" + header.id
            guard key == prefix + "/header", UUID(uuidString: header.id) != nil, (1...84).contains(header.parts) else { throw DeviceShareError.invalid }
            var payload = Data()
            for index in 0..<header.parts {
                guard let part = try replica.value(prefix + "/part/\(index)", as: Data.self), !part.isEmpty, part.count <= 300_000 else { throw DeviceShareError.invalid }
                payload.append(part)
            }
            guard payload.count <= 25_000_000, DeviceShareCodec.digest(payload) == header.digest else { throw DeviceShareError.invalid }
            if let old = next.references.first(where: { $0.id == header.id }) {
                guard try DeviceShareCodec.encode(old) == payload else { throw EvaluationFailure.message("같은 기준 버전의 다른 내용이 공유되어 기존 기준을 보존합니다.") }
            } else {
                let reference = try DeviceShareCodec.decode(EvaluationReference.self, payload)
                try reference.validate(); guard reference.id == header.id else { throw DeviceShareError.invalid }
                next.references.append(reference)
            }
        }
        next.references.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        try next.configuration.validate()
        guard next.sites.count <= 5_000, next.references.count <= 50,
              next.configuration.activeReferenceID.map({ id in next.references.contains { $0.id == id } }) ?? true else { throw DeviceShareError.invalid }
        if next != archive { try commit(next) }
    }
}
