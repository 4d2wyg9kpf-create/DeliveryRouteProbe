import Foundation

protocol RealtyHousingCollecting {
    func areas(sido: String, sigungu: String) async throws -> [HousingArea]
    func list(sido: HousingArea, sigungu: HousingArea, dong: HousingArea) async throws -> HousingRegion
    func detail(_ source: HousingSource) async throws -> HousingSource
}

enum HousingCollectionScope {
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

struct HousingCollectionTarget: Identifiable {
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

// Freeze the scope's legal-dong denominator before collecting any apartment
// lists. Detail counts belong to the active dong's initial missing-ID snapshot.
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
    mutating func detailFinished(_ id: String, successful: Bool) {
        guard targetDetailIDs?.contains(id) == true else { return }
        if successful { completedDetailIDs.insert(id); failedDetailIDs.remove(id) }
        else if !completedDetailIDs.contains(id) { failedDetailIDs.insert(id) }
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
    var fraction: Double? {
        guard let total = targetRegionIDs?.count, total > 0 else { return nil }
        return Double(completedRegionIDs.count) / Double(total)
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
        var text = "\(scopeTitle) · 법정동 \(includesDetails ? "수집" : "목록 확인") 완료 \(completedRegionIDs.count)/\(total)"
        if let percentage { text += " (\(percentage))" }
        if !failedRegionIDs.isEmpty { text += " · 미완료 \(failedRegionIDs.count)곳" }
        return text
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
