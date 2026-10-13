import Foundation

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw EvaluationFailure.message(message) }
}
private func close(_ actual: Double, _ expected: Double, tolerance: Double = 1e-12) throws {
    try require(abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)")
}
private func rejects(_ action: () throws -> Void) throws {
    var rejected = false
    do { try action() } catch { rejected = true }
    try require(rejected, "invalid operation accepted")
}
private func site(_ index: Int) -> EvaluationSite {
    EvaluationSite(id: "site/manual/fixture-\(index)", name: "가상 대상 \(index)", address: "대전광역시 가상로 \(index)", longitude: 127.4 + Double(index) / 100_000, latitude: 36.3)
}
private func replica(_ snapshot: DeviceShareSnapshot) throws -> DeviceShareReplica {
    var result = DeviceShareReplica(deviceID: UUID().uuidString)
    var observed: [String: Data] = [:]
    try result.capture(snapshot, observed: &observed); try result.validate(); return result
}

@main struct EvaluationReferenceChecks {
    @MainActor static func main() throws {
        var passed = 0
        func check(_ name: String, _ action: () throws -> Void) throws { try action(); passed += 1; print("PASS \(name)") }
        let date = ISO8601DateFormatter().date(from: "2026-10-13T10:30:00Z")!
        let conditions = EvaluationConditions(departure: EvaluationConditions.nextNovemberMonday(now: date), description: "가상 고정 조건")
        let criterion = EvaluationCriterion(title: "가상 소요시간", major: "교통", middle: "도로", unit: "초")
        let three = [site(1), site(2), site(3)]
        let standards = zip(three, [10.0, 20.0, 30.0]).map { EvaluationStandard(site: $0.0, weight: 1, values: [criterion.id: $0.1]) }
        let distribution = try EvaluationDistribution.fit(criterion, standards: standards)

        try check("default evaluation departure is first November Monday 08:00 Korea") {
            try require(KoreanDate.string(conditions.departure) == "2026-11-02 08:00", "wrong fixed departure")
            let afterNovember = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
            try require(KoreanDate.string(EvaluationConditions.nextNovemberMonday(now: afterNovember)) == "2027-11-01 08:00", "wrong following year")
        }
        try check("unweighted sample mean and sample standard deviation") {
            try close(distribution.mean, 20); try close(distribution.standardDeviation, 10)
            try close(distribution.effectiveCount, 3)
        }
        try check("normal CDF center and +/- one standard deviation") {
            try close(try distribution.score(20), 0.5)
            try close(try distribution.score(10), 0.8413447460685429)
            try close(try distribution.score(30), 0.15865525393145707)
        }
        try check("higher-is-better reverses lower-is-better") {
            var higher = distribution; higher.criterion.direction = .higher
            for raw in [0.0, 10, 20, 30, 100] { try close(try higher.score(raw) + distribution.score(raw), 1) }
        }
        try check("extreme positive tail remains finite and tiny probabilities survive") {
            try close(try distribution.score(1_000_000), 0)
            let tail = try distribution.score(120)
            try require(tail > 0 && tail < 1e-20, "tail lost by 1-CDF subtraction")
        }
        try check("scores are monotonic, bounded and equal raw ranks tie") {
            let values = try (0...200).map { try distribution.score(Double($0)) }
            try require(values.allSatisfy { (0...1).contains($0) } && zip(values, values.dropFirst()).allSatisfy { $0 >= $1 }, "monotonic bounds")
            try close(try distribution.score(15), try distribution.score(15))
        }
        try check("weight scaling does not change the reference distribution") {
            var weighted = standards; weighted[2].weight = 2
            let a = try EvaluationDistribution.fit(criterion, standards: weighted)
            let b = try EvaluationDistribution.fit(criterion, standards: weighted.map { EvaluationStandard(site: $0.site, weight: $0.weight * 100, values: $0.values) })
            try close(a.mean, 22.5); try close(a.standardDeviation, sqrt(110)); try close(a.effectiveCount, 8.0 / 3)
            try close(a.mean, b.mean); try close(a.standardDeviation, b.standardDeviation)
        }
        try check("large close values use stable variance instead of squared-sum cancellation") {
            let large = zip(three, [1e12 - 1, 1e12, 1e12 + 1]).map { EvaluationStandard(site: $0.0, weight: 1, values: [criterion.id: $0.1]) }
            let fitted = try EvaluationDistribution.fit(criterion, standards: large)
            try close(fitted.standardDeviation, 1); try close(fitted.mean, 1e12)
        }
        try check("constant samples and single samples cannot silently create scores") {
            try rejects { _ = try EvaluationDistribution.fit(criterion, standards: Array(standards.prefix(1))) }
            try rejects { _ = try EvaluationDistribution.fit(criterion, standards: standards.map { EvaluationStandard(site: $0.site, weight: 1, values: [criterion.id: 10]) }) }
        }
        try check("nonfinite negative missing values and invalid weights are rejected") {
            for raw in [Double.nan, .infinity, -1] { try rejects { _ = try distribution.score(raw) } }
            var broken = standards; broken[0].values = [:]
            try rejects { _ = try EvaluationDistribution.fit(criterion, standards: broken) }
            for weight in [0.0, -1, Double.infinity] {
                broken = standards; broken[0].weight = weight
                try rejects { _ = try EvaluationDistribution.fit(criterion, standards: broken) }
            }
        }

        var bytes: Data?
        let store = EvaluationReferenceStore(read: { bytes }, write: { bytes = $0 })
        try store.saveConditions(departure: conditions.departure, description: conditions.description)
        try store.saveCriterion(criterion)
        let context = store.archive.configuration.conditions
        for (index, target) in three.enumerated() {
            try store.setStandard(target, weight: 1)
            try store.saveObservations(site: target, criteria: [criterion], conditions: context,
                values: [criterion.id: Double((index + 1) * 10)], source: "가상 원자료", now: date)
        }
        let baseline = try store.preview(title: "가상 전국 기준 1", sites: three)
        try store.confirm(baseline)
        let other = site(4)
        try store.saveObservations(site: other, criteria: [criterion], conditions: context, values: [criterion.id: 15], source: "가상 자료", now: date)
        let originalScore = try store.result(site: other, reference: baseline).total!

        try check("new nonreference target is scored against frozen coefficients") {
            try close(originalScore, 0.6914624612740131)
            try require(baseline.standards.count == 3 && store.active?.id == baseline.id, "sample mutated")
        }
        try check("adding extreme new targets does not change existing scores") {
            try store.saveObservations(site: site(5), criteria: [criterion], conditions: context, values: [criterion.id: 9000], source: "가상 자료")
            try close(try store.result(site: other, reference: store.active!).total!, originalScore)
            try require(store.active == baseline, "reference refitted")
        }
        try check("new evaluation targets do not request a reference update") {
            try require(!store.needsReferenceUpdate(sites: three + [other, site(5)]), "nonreference target changed the reference")
            try close(try store.currentResult(site: other).total!, originalScore)
        }
        try check("reference membership weights and coordinates signal a required global update") {
            try store.setStandard(three[0], weight: 2)
            try require(store.needsReferenceUpdate(sites: three), "changed weight not detected")
            try store.setStandard(three[0], weight: 1)
            try require(!store.needsReferenceUpdate(sites: three), "unchanged sample marked dirty")
            try store.setStandard(three[2], weight: nil)
            try require(store.needsReferenceUpdate(sites: three), "changed membership not detected")
            try store.setStandard(three[2], weight: 1)
            var moved = three; moved[0].longitude += 0.01
            try require(store.needsReferenceUpdate(sites: moved), "changed standard coordinate not detected")
            try require(!store.needsReferenceUpdate(sites: three), "restored selection remains dirty")
        }
        try check("editing reference raw data does not refit an already confirmed version") {
            try store.saveObservations(site: three[2], criteria: [criterion], conditions: context, values: [criterion.id: 90], source: "수정한 가상 자료")
            try require(store.active == baseline && baseline.standards[2].values[criterion.id] == 30, "frozen observations overwritten")
            try require(store.needsReferenceUpdate(sites: three), "changed reference observation not detected")
            try close(try store.result(site: other, reference: store.active!).total!, originalScore)
        }
        try check("changed membership changes only the next reference preview") {
            try store.setStandard(site(5), weight: 1)
            try store.setStandard(three[0], weight: nil)
            try require(store.active == baseline, "standard toggle mutated active reference")
            try store.setStandard(site(5), weight: nil); try store.setStandard(three[0], weight: 1)
        }
        try check("new versions are separate and previous version can be reapplied") {
            let revised = try store.preview(title: "가상 전국 기준 2", sites: three)
            try store.confirm(revised)
            try require(revised.id != baseline.id && store.archive.references.count == 2 && store.active?.id == revised.id, "version identity")
            try close(revised.distributions[0].mean, 40)
            try close(revised.distributions[0].standardDeviation, sqrt(1900))
            try close(try store.result(site: other, reference: revised).total!, 0.7168602129773354)
            // All previously evaluated targets immediately use the active version, without fetching raw data again.
            let first = try store.currentResult(site: other), second = try store.currentResult(site: three[1])
            try require(first.referenceID == revised.id && second.referenceID == revised.id, "some targets kept an old reference")
            try close(first.total!, 0.7168602129773354); try close(second.total!, 0.6768224022302549)
            try require(!store.needsReferenceUpdate(sites: three), "newly confirmed sample remains dirty")
            try store.activate(baseline.id)
            try close(try store.currentResult(site: other).total!, originalScore)
            try close(try store.currentResult(site: three[1]).total!, 0.5)
        }
        try check("confirmed model and raw observations survive recreation") {
            let reopened = EvaluationReferenceStore(read: { bytes }, write: { bytes = $0 })
            try require(reopened.errorMessage == nil && reopened.active == baseline, "load persisted reference")
            try close(try reopened.result(site: other, reference: reopened.active!).total!, originalScore)
        }
        try check("coordinate changes invalidate raw data and do not move the frozen sample") {
            var moved = other; moved.longitude += 0.01
            let result = try store.result(site: moved, reference: baseline)
            try require(result.total == nil && result.missing == [criterion.title], "old coordinate reused")
            var movedStandard = three; movedStandard[0].latitude += 0.01
            try rejects { _ = try store.preview(title: "좌표 변경", sites: movedStandard) }
            try require(store.active == baseline, "frozen coordinates changed")
        }
        try check("deleting a selected standard blocks incomplete reference fitting") {
            try rejects { _ = try store.preview(title: "삭제된 표준 대상", sites: Array(three.dropFirst())) }
            try require(store.active == baseline, "existing version removed")
        }
        try check("different conditions cannot mix old observations into a new reference") {
            try store.saveConditions(departure: context.departure.addingTimeInterval(3600), description: "다른 가상 조건")
            try rejects { _ = try store.preview(title: "다른 조회 조건", sites: three) }
            try close(try store.result(site: other, reference: baseline).total!, originalScore)
        }
        try check("edited units create a new definition and retain old version usability") {
            var edited = criterion; edited.unit = "분"
            try store.saveCriterion(edited)
            try require(store.archive.configuration.criteria[0].revision != criterion.revision, "definition revision reused")
            try rejects { _ = try store.preview(title: "다른 단위", sites: three) }
            try close(try store.result(site: other, reference: baseline).total!, originalScore)
        }
        try check("blank inputs remove observations instead of creating zeros") {
            let missing = site(6)
            try store.saveObservations(site: missing, criteria: [criterion], conditions: context, values: [:], source: "")
            try require(try store.result(site: missing, reference: baseline).total == nil, "blank treated as zero")
            try store.saveObservations(site: missing, criteria: [criterion], conditions: context, values: [criterion.id: 0], source: "실제 0")
            try require(try store.result(site: missing, reference: baseline).total != nil, "measured zero lost")
            try store.saveObservations(site: missing, criteria: [criterion], conditions: context, values: [:], source: "")
            try require(try store.result(site: missing, reference: baseline).total == nil, "deleted observation kept")
        }
        try check("duplicate selected site identities cannot distort the sample") {
            try rejects { _ = try EvaluationReference.freeze(title: "중복", conditions: context, criteria: [criterion], sites: three + [three[0]], records: store.archive.sites) }
        }
        try check("identical item names in the same hierarchy are rejected") {
            var duplicate = criterion; duplicate.id = UUID().uuidString; duplicate.revision = UUID().uuidString
            try rejects { try EvaluationReference.validateCriteria([criterion, duplicate]) }
        }
        try check("persisted coefficients are checked against the frozen sample") {
            var bad = baseline; bad.distributions[0].mean += 1
            try rejects { try bad.validate() }
        }
        try check("corrupt archives are preserved and writes stay blocked") {
            let original = Data("invalid-evaluation-fixture".utf8)
            var corrupted = original
            let broken = EvaluationReferenceStore(read: { corrupted }, write: { corrupted = $0 })
            try rejects { try broken.setStandard(other, weight: 1) }
            try require(broken.errorMessage != nil && corrupted == original, "corrupt archive overwritten")
        }
        try check("failed disk writes do not publish an unpersisted mutation") {
            let failing = EvaluationReferenceStore(read: { nil }, write: { _ in throw EvaluationFailure.message("injected write failure") })
            try rejects { try failing.setStandard(other, weight: 1) }
            try require(failing.archive.sites.isEmpty, "failed write published")
        }
        try check("device sharing uses stable site keys and includes exact immutable versions") {
            let snapshot = try store.sharingSnapshot(), shared = try replica(snapshot)
            let receiving = EvaluationReferenceStore(read: { nil }, write: { _ in })
            try receiving.applySharing(shared)
            try require(receiving.active == baseline && receiving.archive.sites[other.id] != nil, "shared identity/version lost")
            try close(try receiving.result(site: other, reference: receiving.active!).total!, originalScore)
            try receiving.applySharing(shared)
            try require(receiving.archive.references.count == 2, "repeated sync duplicated versions")
        }
        try check("partial shared reference pieces cannot replace a working baseline") {
            var shared = try replica(store.sharingSnapshot())
            let key = "setting/evaluation/reference/" + baseline.id + "/part/0"
            shared.records.removeValue(forKey: key)
            try rejects { try store.applySharing(shared) }
            try require(store.active == baseline, "partial sharing changed active reference")
        }
        try check("uninitialized second device does not publish a competing empty configuration") {
            let empty = EvaluationReferenceStore(read: { nil }, write: { _ in })
            try require(try empty.sharingSnapshot().values.isEmpty, "default state overwrites remote configuration")
        }
        try check("same version ID with different shared content cannot overwrite the original") {
            var changed = baseline; changed.title = "같은 ID의 다른 가상 기준"
            let conflicting = EvaluationReferenceStore(read: { nil }, write: { _ in })
            try conflicting.confirm(changed)
            try rejects { try store.applySharing(try replica(conflicting.sharingSnapshot())) }
            try require(store.active == baseline, "immutable version overwritten")
        }
        try check("large frozen samples are shared in bounded checksummed pieces") {
            let many = (1...2_000).map { index in
                EvaluationStandard(site: site(index), weight: 1, values: [criterion.id: Double(index)])
            }
            let large = EvaluationReference(title: "큰 가상 표본", createdAt: date, conditions: context, standards: many,
                distributions: [try EvaluationDistribution.fit(criterion, standards: many)])
            let origin = EvaluationReferenceStore(read: { nil }, write: { _ in })
            try origin.confirm(large)
            let snapshot = try origin.sharingSnapshot()
            try require(snapshot.values.keys.filter { $0.contains("/part/") }.count >= 2 && snapshot.values.values.allSatisfy { $0.count <= 500_000 }, "large snapshot not split")
            let recipient = EvaluationReferenceStore(read: { nil }, write: { _ in })
            try recipient.applySharing(try replica(snapshot))
            try require(recipient.active == large, "large reference not restored exactly")
        }

        // Deliberately unequal hierarchy: flat average would give a different result.
        try check("equal weights are applied at item, middle and major levels") {
            let hierarchy = [
                EvaluationCriterion(title: "A1", major: "A", middle: "A-1", unit: "개", direction: .higher),
                EvaluationCriterion(title: "A2", major: "A", middle: "A-1", unit: "개", direction: .higher),
                EvaluationCriterion(title: "A3", major: "A", middle: "A-2", unit: "개", direction: .higher),
                EvaluationCriterion(title: "B1", major: "B", middle: "B-1", unit: "개", direction: .higher)]
            let sample = zip(three, [10.0, 20, 30]).map { s, x in EvaluationStandard(site: s, weight: 1, values: Dictionary(uniqueKeysWithValues: hierarchy.map { ($0.id, x) })) }
            let reference = EvaluationReference(title: "계층 가상 기준", createdAt: date, conditions: context, standards: sample,
                distributions: try hierarchy.map { try EvaluationDistribution.fit($0, standards: sample) })
            var record = EvaluationSiteRecord(site: other)
            for (index, item) in hierarchy.enumerated() {
                let observation = EvaluationObservation(conditionsID: context.id, criterionID: item.id, criterionRevision: item.revision,
                    value: index < 2 ? 30 : 10, longitude: other.longitude, latitude: other.latitude, observedAt: date, source: "가상")
                record.observations[observation.id] = observation
            }
            let result = try reference.evaluate(site: other, record: record)
            try close(result.majorScores["A"]!, 0.5)
            try close(result.total!, (0.5 + 0.15865525393145707) / 2)
            record.observations.removeValue(forKey: context.id + "/" + hierarchy[0].revision)
            let partial = try reference.evaluate(site: other, record: record)
            try require(partial.total == nil && partial.majorScores.isEmpty && partial.scores.count == 3, "missing leaf silently changes weights")
        }
        print("\(passed)/\(passed) fixed evaluation reference checks passed")
    }
}
private enum KoreanDate {
    static func string(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Seoul"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: date)
    }
}
