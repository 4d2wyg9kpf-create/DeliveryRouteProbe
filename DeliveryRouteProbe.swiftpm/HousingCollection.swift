import Foundation

protocol RealtyHousingCollecting {
    func areas(sido: String, sigungu: String) async throws -> [HousingArea]
    func list(sido: HousingArea, sigungu: HousingArea, dong: HousingArea) async throws -> HousingRegion
    func detail(_ source: HousingSource) async throws -> HousingSource
}

enum HousingCollectionScope: Codable {
    case nationwide
    case province(HousingArea)
    case district(HousingArea, HousingArea)
    case dong(HousingArea, HousingArea, HousingArea)
    var title: String {
        switch self {
        case .nationwide: return "전국"
        case .province(let s): return s.name
        case .district(let s, let g): return s.name + " " + g.name
        case .dong(let s, let g, let d): return s.name + " " + g.name + " " + d.name
        }
    }
    var buttonPrefix: String {
        switch self {
        case .nationwide: return "전국"
        case .province: return "선택 시도"
        case .district: return "선택 시군구"
        case .dong: return "선택 법정동"
        }
    }
}

struct HousingCollectionTarget: Identifiable, Codable {
    let sido: HousingArea
    let sigungu: HousingArea
    let dong: HousingArea
    var id: String { sido.code + sigungu.code + dong.code }
    var title: String { sido.name + " " + sigungu.name + " " + dong.name }
}

enum HousingCollectionTargets {
    @MainActor
    static func resolve(_ scope: HousingCollectionScope, client: any RealtyHousingCollecting,
                        onDiscovered: (Int) -> Void = { _ in }) async throws -> [HousingCollectionTarget] {
        var targets: [HousingCollectionTarget] = [], seen = Set<String>()
        func append(_ s: HousingArea, _ g: HousingArea, _ d: HousingArea) throws {
            let target = HousingCollectionTarget(sido: s, sigungu: g, dong: d)
            guard target.id.range(of: #"^\d{10}$"#, options: .regularExpression) != nil else {
                throw PlannerFailure.message("수집 대상 법정동 코드를 확인하지 못했습니다.")
            }
            if seen.insert(target.id).inserted { targets.append(target); onDiscovered(targets.count) }
        }
        func appendDistrict(_ s: HousingArea, _ g: HousingArea) async throws {
            try Task.checkCancellation()
            for d in try await client.areas(sido: s.code, sigungu: g.code) {
                try Task.checkCancellation(); try append(s, g, d)
            }
        }
        func appendProvince(_ s: HousingArea) async throws {
            try Task.checkCancellation()
            for g in try await client.areas(sido: s.code, sigungu: "") { try await appendDistrict(s, g) }
        }
        try Task.checkCancellation()
        switch scope {
        case .dong(let s, let g, let d): try append(s, g, d)
        case .district(let s, let g): try await appendDistrict(s, g)
        case .province(let s): try await appendProvince(s)
        case .nationwide:
            for s in try await client.areas(sido: "", sigungu: "") { try await appendProvince(s) }
        }
        return targets
    }
}

// Inventory first, then freeze the apartment denominator for the entire job.
// A source ID is qualified by region so overlapping source lists cannot skew it.
struct HousingCollectionProgress {
    enum Phase { case discovering, list, details, finished, stopped, failed }
    let scopeTitle: String
    let includesDetails: Bool
    private(set) var phase = Phase.discovering
    private(set) var discoveredRegions = 0
    private(set) var targetRegionIDs: Set<String>?
    private(set) var completedRegionIDs = Set<String>()
    private(set) var failedRegionIDs = Set<String>()
    private(set) var currentRegionID = ""
    private(set) var currentRegionTitle = ""
    private(set) var targetDetailIDs: Set<String>?
    private(set) var completedDetailIDs = Set<String>()
    private(set) var failedDetailIDs = Set<String>()
    private(set) var previouslyCompletedDetails = 0
    private(set) var inventory: [String: Set<String>] = [:]
    private(set) var inventorySealed = false
    private(set) var completedByRegion: [String: Set<String>] = [:]
    private(set) var completedComplexCount = 0
    private(set) var totalComplexCount: Int?
    private(set) var allFailedIDs = Set<String>()
    private(set) var durations: [TimeInterval] = []
    private(set) var attemptStartedAt: Date?

    private func key(_ region: String, _ id: String) -> String { region + "/" + id }

    mutating func discovered(_ count: Int) { discoveredRegions = max(discoveredRegions, count) }
    mutating func setTargets(_ ids: [String]) {
        guard targetRegionIDs == nil else { return }
        targetRegionIDs = Set(ids); discoveredRegions = targetRegionIDs!.count
    }
    mutating func beginRegion(id: String, title: String) {
        currentRegionID = id; currentRegionTitle = title; phase = .list
        targetDetailIDs = nil; completedDetailIDs = []; failedDetailIDs = []; previouslyCompletedDetails = 0
    }
    mutating func beginDetails(ids: [String], previouslyCompleted: Int) {
        guard targetDetailIDs == nil else { return }
        targetDetailIDs = Set(ids); previouslyCompletedDetails = max(0, previouslyCompleted); phase = .details
    }
    mutating func recordInventory(regionID: String, ids: [String], completedIDs: Set<String>) {
        guard !inventorySealed, inventory[regionID] == nil else { return }
        let unique = Set(ids); inventory[regionID] = unique
        let completed = unique.intersection(completedIDs)
        completedByRegion[regionID] = completed; completedComplexCount += completed.count
    }
    mutating func sealInventory() {
        guard let targets = targetRegionIDs, targets.allSatisfy({ inventory[$0] != nil }) else { return }
        inventorySealed = true; totalComplexCount = inventory.values.reduce(0) { $0 + $1.count }
    }
    mutating func reconcileCompleted(regionID: String, ids: Set<String>) {
        for id in (inventory[regionID] ?? []).intersection(ids) {
            if completedByRegion[regionID, default: []].insert(id).inserted { completedComplexCount += 1 }
            allFailedIDs.remove(key(regionID, id))
        }
    }
    mutating func beginAttempt(at: Date = Date()) { attemptStartedAt = at }
    mutating func recordAttempt(at: Date = Date()) {
        if let start = attemptStartedAt {
            let duration = at.timeIntervalSince(start)
            if duration.isFinite, duration > 0 { durations.append(duration); durations = Array(durations.suffix(20)) }
        }
        attemptStartedAt = nil
    }
    mutating func detailFinished(_ id: String, successful: Bool) {
        guard targetDetailIDs?.contains(id) == true else { return }
        if successful { completedDetailIDs.insert(id); failedDetailIDs.remove(id) }
        else if !completedDetailIDs.contains(id) { failedDetailIDs.insert(id) }
        guard inventory[currentRegionID]?.contains(id) == true else { return }
        let qualified = key(currentRegionID, id)
        if successful {
            if completedByRegion[currentRegionID, default: []].insert(id).inserted { completedComplexCount += 1 }
            allFailedIDs.remove(qualified)
        } else if completedByRegion[currentRegionID]?.contains(id) != true { allFailedIDs.insert(qualified) }
    }
    mutating func regionFinished(successful: Bool) {
        guard targetRegionIDs?.contains(currentRegionID) == true else { return }
        if successful { completedRegionIDs.insert(currentRegionID); failedRegionIDs.remove(currentRegionID) }
        else if !completedRegionIDs.contains(currentRegionID) { failedRegionIDs.insert(currentRegionID) }
    }
    mutating func finish() { phase = .finished }
    mutating func stop() { phase = .stopped }
    mutating func fail() { phase = .failed }
    var detailTotalCount: Int? { targetDetailIDs.map { previouslyCompletedDetails + $0.count } }
    var detailCompletedCount: Int { previouslyCompletedDetails + completedDetailIDs.count }
    var remainingComplexCount: Int? { totalComplexCount.map { max(0, $0 - completedComplexCount) } }
    var fraction: Double? {
        guard let total = totalComplexCount else { return nil }
        if !includesDetails { return phase == .finished ? 1 : nil }
        return total == 0 ? 1 : min(1, Double(completedComplexCount) / Double(total))
    }
    var percentage: String? {
        guard let fraction else { return nil }
        // Never round an unfinished large scope up to 100%.
        let value = fraction >= 1 ? 100 : floor(fraction * 1_000) / 10
        return String(format: "%.1f%%", value)
    }
    var summary: String {
        guard let total = targetRegionIDs?.count else {
            return "\(scopeTitle) · 수집 대상 법정동 확인 중 \(discoveredRegions)곳"
        }
        guard let complexTotal = totalComplexCount else {
            let known = inventory.values.reduce(0) { $0 + $1.count }
            return "\(scopeTitle) · 전체 단지 수 확인 중 · 현재 \(known)단지\n목록 확인 \(inventory.count)/\(total)곳"
        }
        var text = includesDetails ? "\(scopeTitle) · 단지 완료 \(completedComplexCount)/\(complexTotal)" : "\(scopeTitle) · 단지 목록 확인 \(complexTotal)건"
        if let percentage { text += " (\(percentage))" }
        if !allFailedIDs.isEmpty { text += " · 상세 미완료 \(allFailedIDs.count)단지" }
        return text
    }
    func estimatedRemaining(at now: Date = Date()) -> TimeInterval? {
        guard includesDetails, let remaining = remainingComplexCount else { return nil }
        if remaining == 0 { return 0 }
        guard durations.count >= 3, allFailedIDs.isEmpty, phase == .details else { return nil }
        let average = durations.reduce(0, +) / Double(durations.count)
        let current = attemptStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(average, average * Double(remaining) - min(current, average))
    }
    func estimateText(at now: Date = Date()) -> String {
        if !includesDetails { return "" }
        if phase == .stopped || phase == .failed { return "예상 남은 시간: 수집을 재개하면 다시 계산합니다." }
        if remainingComplexCount == 0 { return "예상 남은 시간: 0분" }
        if !allFailedIDs.isEmpty { return "예상 남은 시간: 미완료 단지 재수집 후 다시 계산합니다." }
        guard let seconds = estimatedRemaining(at: now) else {
            return inventorySealed ? "예상 남은 시간: 처리 속도 확인 중" : "예상 남은 시간: 전체 단지 수 확인 후 계산합니다."
        }
        let minutes = max(1, Int(ceil(seconds / 60)))
        let duration = minutes >= 1440 ? "\(minutes / 1440)일 \((minutes % 1440) / 60)시간" : minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M/d HH:mm"
        return "예상 남은 시간: 약 \(duration) · 완료 약 \(f.string(from: now.addingTimeInterval(seconds)))"
    }
    var text: String {
        switch phase {
        case .discovering: return summary
        case .list: return summary + "\n" + currentRegionTitle + " · 단지 목록 확인 중"
        case .details:
            let total = targetDetailIDs?.count ?? 0
            let detail = "상세 \(detailCompletedCount)/\(detailTotalCount ?? 0)"
            let pending = total == 0 ? "이번에 수집할 상세 없음" : "이번 완료 \(completedDetailIDs.count)/\(total) · 실패 \(failedDetailIDs.count)건"
            return summary + "\n" + currentRegionTitle + " · " + detail + " · " + pending
        case .finished: return "수집 종료 · " + summary
        case .stopped: return "수집 중단 · " + summary + "\n저장된 자료에서 다시 이어갈 수 있습니다."
        case .failed: return "수집 보류 · " + summary + "\n저장된 자료를 유지했습니다."
        }
    }
}

struct HousingCollectionCheckpoint: Codable {
    var version = 1
    var scope: HousingCollectionScope
    var includesDetails: Bool
    var targets: [HousingCollectionTarget]?
    var inventory: [String: [String]] = [:]
    func validate() throws {
        guard version == 1, (targets?.count ?? 0) <= 20_000, inventory.count <= 20_000,
              Set(targets?.map(\.id) ?? []).count == (targets?.count ?? 0),
              inventory.allSatisfy({ code, ids in code.range(of: #"^\d{10}$"#, options: .regularExpression) != nil && ids.count <= 100_000 && Set(ids).count == ids.count && ids.allSatisfy { $0.hasPrefix("realty:" + code.prefix(5) + ":") } }),
              inventory.keys.allSatisfy({ code in targets?.contains { $0.id == code } == true }) else { throw DeviceShareError.invalid }
    }
}
