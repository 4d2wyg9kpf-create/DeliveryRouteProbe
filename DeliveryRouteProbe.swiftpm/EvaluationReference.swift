import Foundation

enum EvaluationFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum EvaluationDirection: String, Codable, CaseIterable, Identifiable {
    case higher, lower
    var id: String { rawValue }
    var title: String { self == .higher ? "클수록 우수" : "작을수록 우수" }
}

struct EvaluationCriterion: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    // A changed definition cannot reinterpret observations from the old definition.
    var revision = UUID().uuidString
    var title: String
    var major: String
    var middle: String
    var unit: String
    var direction: EvaluationDirection = .lower
    func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: revision) != nil,
              [title, major, middle, unit].allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) && $0.utf8.count <= 200 }) else {
            throw EvaluationFailure.message("항목명·대분류·중분류·단위를 확인하세요.")
        }
    }
}

struct EvaluationConditions: Codable, Equatable {
    var id = UUID().uuidString
    var departure: Date = Self.nextNovemberMonday()
    var description = "자동차: 11월 첫째 월요일 08:00 한국시간. 항목마다 같은 제공자·경로 기준·시설 후보군·반경·단위를 사용합니다."
    static func nextNovemberMonday(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var year = calendar.component(.year, from: now)
        if calendar.component(.month, from: now) >= 11 { year += 1 }
        let first = calendar.date(from: DateComponents(year: year, month: 11, day: 1, hour: 8))!
        let offset = (2 - calendar.component(.weekday, from: first) + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: first)!
    }
    func validate() throws {
        guard UUID(uuidString: id) != nil, departure.timeIntervalSince1970.isFinite,
              (0...4_102_444_800).contains(departure.timeIntervalSince1970),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.utf8.count <= 4_000 else {
            throw EvaluationFailure.message("평가 기준 시각과 조회 조건을 확인하세요.")
        }
    }
}

struct EvaluationSite: Codable, Equatable, Identifiable {
    // SiteTargetStore.sharingKey, rather than a device-local record ID.
    var id: String
    var name: String
    var address: String
    var longitude: Double
    var latitude: Double
    func validate() throws {
        guard id.hasPrefix("site/"), id.utf8.count <= 512, !name.isEmpty, name.utf8.count <= 1_000,
              address.utf8.count <= 4_000, longitude.isFinite, latitude.isFinite,
              (124...132).contains(longitude), (32...40).contains(latitude) else {
            throw EvaluationFailure.message("평가대상지 이름과 좌표를 확인하세요.")
        }
    }
}

struct EvaluationObservation: Codable, Equatable, Identifiable {
    var conditionsID: String
    var criterionID: String
    var criterionRevision: String
    var value: Double
    var longitude: Double
    var latitude: Double
    var observedAt: Date
    var source: String
    var id: String { conditionsID + "/" + criterionRevision }
    func matches(_ criterion: EvaluationCriterion, conditions: EvaluationConditions, site: EvaluationSite) -> Bool {
        conditionsID == conditions.id && criterionID == criterion.id && criterionRevision == criterion.revision &&
            longitude == site.longitude && latitude == site.latitude
    }
    func validate() throws {
        guard [conditionsID, criterionID, criterionRevision].allSatisfy({ UUID(uuidString: $0) != nil }),
              value.isFinite, value >= 0, longitude.isFinite, latitude.isFinite,
              (124...132).contains(longitude), (32...40).contains(latitude),
              observedAt.timeIntervalSince1970.isFinite, source.utf8.count <= 1_000 else {
            throw EvaluationFailure.message("원자료의 수치·단위·좌표를 확인하세요. 누락값은 0으로 입력하지 않습니다.")
        }
    }
}

struct EvaluationSiteRecord: Codable, Equatable {
    var site: EvaluationSite
    var standardWeight: Double?
    var observations: [String: EvaluationObservation] = [:]
    func value(_ criterion: EvaluationCriterion, conditions: EvaluationConditions, site current: EvaluationSite) -> Double? {
        let key = conditions.id + "/" + criterion.revision
        guard let observation = observations[key], observation.matches(criterion, conditions: conditions, site: current) else { return nil }
        return observation.value
    }
    func validate() throws {
        try site.validate()
        guard standardWeight.map({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) ?? true, observations.count <= 1_000 else {
            throw EvaluationFailure.message("표준 대상의 표본 가중치를 확인하세요.")
        }
        for (key, observation) in observations { try observation.validate(); guard key == observation.id else { throw EvaluationFailure.message("원자료 식별자가 다릅니다.") } }
    }
}

struct EvaluationStandard: Codable, Equatable {
    var site: EvaluationSite
    var weight: Double
    var values: [String: Double]
}

struct EvaluationDistribution: Codable, Equatable {
    var criterion: EvaluationCriterion
    var count: Int
    var effectiveCount: Double
    var mean: Double
    var standardDeviation: Double
    var minimum: Double
    var maximum: Double

    static func fit(_ criterion: EvaluationCriterion, standards: [EvaluationStandard]) throws -> Self {
        try criterion.validate()
        guard standards.count >= 2, let largest = standards.map(\.weight).max(), largest.isFinite, largest > 0 else {
            throw EvaluationFailure.message("기준분포에는 원자료를 확인한 표준 대상이 2곳 이상 필요합니다.")
        }
        // Scale weights first; weighted Welford avoids subtracting large squared sums.
        var sum = 0.0, squares = 0.0, mean = 0.0, m2 = 0.0
        var minimum = Double.infinity, maximum = -Double.infinity
        for standard in standards {
            guard let x = standard.values[criterion.id], x.isFinite, x >= 0,
                  standard.weight.isFinite, standard.weight > 0, standard.weight <= 1_000_000 else {
                throw EvaluationFailure.message("\(standard.site.name): ‘\(criterion.title)’ 원자료가 없습니다.")
            }
            let w = standard.weight / largest, next = sum + w, delta = x - mean
            mean += delta * (w / next)
            m2 += w * delta * (x - mean)
            sum = next; squares += w * w
            minimum = min(minimum, x); maximum = max(maximum, x)
        }
        let denominator = sum - squares / sum
        let deviation = sqrt(m2 / denominator)
        guard mean.isFinite, denominator.isFinite, denominator > 0, deviation.isFinite, deviation > 0 else {
            throw EvaluationFailure.message("‘\(criterion.title)’의 표준편차가 0이거나 계산할 수 없습니다. 서로 다른 수치를 가진 표준 대상을 확인하세요.")
        }
        return Self(criterion: criterion, count: standards.count, effectiveCount: sum * sum / squares,
                    mean: mean, standardDeviation: deviation, minimum: minimum, maximum: maximum)
    }

    func score(_ raw: Double) throws -> Double {
        guard raw.isFinite, raw >= 0, mean.isFinite, standardDeviation.isFinite, standardDeviation > 0 else {
            throw EvaluationFailure.message("점수 계산에 사용할 수치와 기준분포를 확인하세요.")
        }
        let z = (raw - mean) / standardDeviation
        // erfc also preserves small tail probabilities; avoid 1 - CDF cancellation.
        let score = 0.5 * erfc((criterion.direction == .higher ? -z : z) / sqrt(2))
        guard score.isFinite else { throw EvaluationFailure.message("정규화 점수를 계산하지 못했습니다.") }
        return min(1, max(0, score))
    }
}

struct EvaluationReference: Codable, Equatable, Identifiable {
    var populationToken: String? = nil
    var id = UUID().uuidString
    var algorithmVersion = 1
    var title: String
    var createdAt: Date
    var conditions: EvaluationConditions
    var standards: [EvaluationStandard]
    var distributions: [EvaluationDistribution]
    var criteria: [EvaluationCriterion] { distributions.map(\.criterion) }

    static func freeze(title: String, conditions: EvaluationConditions, criteria: [EvaluationCriterion],
                       sites: [EvaluationSite], records: [String: EvaluationSiteRecord], now: Date = Date()) throws -> Self {
        try conditions.validate(); try validateCriteria(criteria)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 200, !criteria.isEmpty else { throw EvaluationFailure.message("기준 이름과 평가 항목을 입력하세요.") }
        guard Set(sites.map(\.id)).count == sites.count else { throw EvaluationFailure.message("평가대상지가 중복되었습니다.") }
        let available = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0) })
        let selected = records.values.filter { $0.standardWeight != nil }.sorted { $0.site.id < $1.site.id }
        guard selected.count >= 2, selected.count <= 100_000 else { throw EvaluationFailure.message("표준 대상을 2곳 이상 선택하세요.") }
        let standards = try selected.map { record -> EvaluationStandard in
            guard let site = available[record.site.id] else { throw EvaluationFailure.message("표준 대상 ‘\(record.site.name)’이 평가대상지 목록에 없습니다. 표준 선택을 확인하세요.") }
            try site.validate(); try record.validate()
            var values: [String: Double] = [:]
            for criterion in criteria {
                guard let value = record.value(criterion, conditions: conditions, site: site) else {
                    throw EvaluationFailure.message("\(site.name): ‘\(criterion.title)’의 현재 좌표·조회 조건에 맞는 원자료가 없습니다.")
                }
                values[criterion.id] = value
            }
            return EvaluationStandard(site: site, weight: record.standardWeight!, values: values)
        }
        return Self(title: title, createdAt: now, conditions: conditions, standards: standards,
                    distributions: try criteria.map { try EvaluationDistribution.fit($0, standards: standards) })
    }

    static func validateCriteria(_ criteria: [EvaluationCriterion]) throws {
        guard criteria.count <= 100, Set(criteria.map(\.id)).count == criteria.count,
              Set(criteria.map(\.revision)).count == criteria.count else { throw EvaluationFailure.message("평가 항목이 중복되거나 너무 많습니다.") }
        for criterion in criteria { try criterion.validate() }
        let keys = criteria.map { [$0.major, $0.middle, $0.title].joined(separator: "\u{1f}") }
        guard Set(keys).count == keys.count else { throw EvaluationFailure.message("같은 분류에 동일한 이름의 평가 항목이 있습니다.") }
    }

    func validate() throws {
        guard UUID(uuidString: id) != nil, algorithmVersion == 1, !title.isEmpty, title.utf8.count <= 200,
              createdAt.timeIntervalSince1970.isFinite, (2...100_000).contains(standards.count),
              !distributions.isEmpty, Set(standards.map { $0.site.id }).count == standards.count else {
            throw EvaluationFailure.message("저장된 평가 기준 형식을 확인하세요.")
        }
        try conditions.validate(); try Self.validateCriteria(criteria)
        let keys = Set(criteria.map(\.id))
        for standard in standards {
            try standard.site.validate()
            guard Set(standard.values.keys) == keys, standard.weight.isFinite, standard.weight > 0, standard.weight <= 1_000_000 else {
                throw EvaluationFailure.message("기준 표본의 원자료가 다릅니다.")
            }
        }
        // Verify saved coefficients against the frozen sample, never against current targets.
        for distribution in distributions {
            let rebuilt = try EvaluationDistribution.fit(distribution.criterion, standards: standards)
            guard rebuilt == distribution else { throw EvaluationFailure.message("기준분포의 계수가 표준 대상 원자료와 다릅니다.") }
        }
    }

    func evaluate(site: EvaluationSite, record: EvaluationSiteRecord?) throws -> EvaluationResult {
        var scores: [String: Double] = [:], missing: [String] = []
        for distribution in distributions {
            if let value = record?.value(distribution.criterion, conditions: conditions, site: site) {
                scores[distribution.criterion.id] = try distribution.score(value)
            } else { missing.append(distribution.criterion.title) }
        }
        guard missing.isEmpty else { return EvaluationResult(referenceID: id, scores: scores, middleScores: [:], majorScores: [:], total: nil, missing: missing) }
        // Equal weights at EACH level, not a flat average over all leaf items.
        let majors = Dictionary(grouping: criteria, by: \.major)
        var middleScores: [String: Double] = [:], majorScores: [String: Double] = [:]
        for (major, items) in majors {
            let middles = Dictionary(grouping: items, by: \.middle)
            var means: [Double] = []
            for (middle, leaves) in middles {
                let mean = leaves.map { scores[$0.id]! }.sorted().reduce(0, +) / Double(leaves.count)
                middleScores[major + " / " + middle] = mean; means.append(mean)
            }
            majorScores[major] = means.sorted().reduce(0, +) / Double(means.count)
        }
        let total = majorScores.values.sorted().reduce(0, +) / Double(majorScores.count)
        return EvaluationResult(referenceID: id, scores: scores, middleScores: middleScores, majorScores: majorScores, total: total, missing: [])
    }
}

struct EvaluationResult {
    var referenceID: String
    var scores: [String: Double]
    var middleScores: [String: Double]
    var majorScores: [String: Double]
    var total: Double?
    var missing: [String]
}
