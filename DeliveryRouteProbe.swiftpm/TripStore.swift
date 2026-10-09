import Foundation
import Combine
import JavaScriptCore

struct TripBridgeOutput {
    let envelope: TripEnvelope
    let tripData: Data?
}

enum TripBridge {
    static func run(_ method: String, _ arguments: [Any]) throws -> TripBridgeOutput {
        guard let context = JSContext() else { throw PlannerFailure.message("운행 엔진을 열지 못했습니다.") }
        context.evaluateScript(PlannerEngineSource.source)
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "운행 코드 오류") }
        let value = context.objectForKeyedSubscript("DeliveryDrive")?.invokeMethod(method, withArguments: arguments)
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "운행 계산 오류") }
        guard let text = value?.toString(), let data = text.data(using: .utf8) else { throw PlannerFailure.message("운행 결과를 읽지 못했습니다.") }
        let envelope = try JSONDecoder().decode(TripEnvelope.self, from: data)
        guard envelope.ok else { throw PlannerFailure.message(envelope.errors.joined(separator: "\n")) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var rawTrip: Data?
        if let record = object?["trip"] as? [String: Any] {
            rawTrip = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        }
        return TripBridgeOutput(envelope: envelope, tripData: rawTrip)
    }
}

@MainActor
final class TripStore: ObservableObject {
    // One active vehicle record shared by all app windows.
    static let shared = TripStore()
    @Published private(set) var trip: TripSession?
    @Published private(set) var report: TripReport?
    @Published private(set) var forecast: PlannerResult?
    @Published private(set) var drive: DriveStatus?
    @Published private(set) var comparison: DriveComparison?
    @Published private(set) var routeDraft: TripRouteDraft?
    @Published private(set) var routeProposal: TripRouteProposal?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var message = "적재 계획을 확정한 뒤 회사 출발을 기록해 주세요."
    private var recoveryRequired = false
    // Preserve the full engine record instead of losing unknown fields through Codable.
    private var activeData: Data?

    private init() {
        do {
            let url = try Self.activeURL()
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Self.read(url)
                let session = try Self.decode(data)
                let envelope = try TripBridge.run("inspectJSON", [String(decoding: data, as: UTF8.self)]).envelope
                trip = session; report = envelope.report; activeData = data
                forecast = envelope.result; drive = envelope.drive
                message = "마지막 실제 운행 기록을 복원했습니다."
            }
        } catch { recoveryRequired = true; errorMessage = "기존 운행 기록을 보존했습니다. 정상 기록을 가져와 복구해 주세요. \(error.localizedDescription)" }
    }

    private static func directory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = documents.appendingPathComponent("RouteProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func activeURL() throws -> URL { try directory().appendingPathComponent("active-trip.json") }
    private static func read(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128_000_000 else { throw PlannerFailure.message("운행 기록은 128MB까지 읽을 수 있습니다.") }
        return try Data(contentsOf: url)
    }
    private static func decode(_ data: Data) throws -> TripSession {
        guard data.count <= 128_000_000 else { throw PlannerFailure.message("운행 기록이 너무 큽니다.") }
        let value = try JSONDecoder().decode(TripSession.self, from: data)
        guard [1, 2].contains(value.schemaVersion), UUID(uuidString: value.id) != nil,
              value.events.count <= 2000, value.voidedEvents.count <= 2000 else {
            throw PlannerFailure.message("운행 식별자 또는 기록 한도를 확인해 주세요.")
        }
        let planData = try JSONEncoder().encode(value.plan)
        _ = try PlannerStore.decode(planData)
        return value
    }
    private func archiveExisting() throws {
        guard let trip = trip, let data = activeData else { return }
        let folder = try Self.directory().appendingPathComponent("trips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(trip.id + "-" + UUID().uuidString + ".json"), options: .atomic)
    }
    func exportData() throws -> Data {
        guard let data = activeData else { throw PlannerFailure.message("내보낼 운행이 없습니다.") }
        return data
    }
    func start(plan: DeliveryPlan, resultData: Data, minute: Int, afterSave: ((String?) -> Void)? = nil) {
        guard !isBusy else { return }
        guard !recoveryRequired else { errorMessage = "기존 운행 기록을 먼저 복구해 주세요."; return }
        if let report = report, report.phase != "returned" || report.hasCargo {
            errorMessage = "현재 운행의 회사 복귀와 남은 화물 하차를 먼저 기록해 주세요."; return
        }
        do {
            let data = try JSONEncoder().encode(plan)
            perform("createJSON", [String(decoding: data, as: UTF8.self), String(decoding: resultData, as: UTF8.self), minute, UUID().uuidString], archive: true, afterSave: afterSave)
        } catch { errorMessage = error.localizedDescription }
    }
    func record(_ event: TripEvent) {
        guard !isBusy else { return }
        do { perform("recordJSON", [String(decoding: try exportData(), as: UTF8.self), String(decoding: try JSONEncoder().encode(event), as: UTF8.self)], autoRefresh: true) }
        catch { errorMessage = error.localizedDescription }
    }
    func replan() {
        guard !isBusy else { return }
        do { perform("replanJSON", [String(decoding: try exportData(), as: UTF8.self)]) }
        catch { errorMessage = error.localizedDescription }
    }
    func resumeGuidanceIfNeeded() {
        if drive?.needsRefresh == true, report?.phase == "ready", !isBusy { replan() }
    }
    func depart(minute: Int, afterSave: @escaping (String?) -> Void) {
        guard !isBusy else { return }
        do { perform("departJSON", [String(decoding: try exportData(), as: UTF8.self), minute, UUID().uuidString], afterSave: afterSave) }
        catch { errorMessage = error.localizedDescription }
    }
    func compare(capture: Data) {
        guard !isBusy else { return }
        do { perform("compareJSON", [String(decoding: try exportData(), as: UTF8.self), String(decoding: capture, as: UTF8.self)], comparisonOnly: true) }
        catch { errorMessage = error.localizedDescription }
    }
    var routeTargets: [DeliveryLeg] {
        guard let trip = trip, let report = report, report.phase == "ready" else { return [] }
        let used = Set(trip.events.filter { $0.type == "start" || $0.type == "depart" }.compactMap(\.legID))
        return trip.effectivePlan.legs.filter { leg in
            !used.contains(leg.id) && leg.fromID != "depot" &&
            (leg.fromID == report.currentID || !report.completedIDs.contains(leg.fromID)) &&
            (leg.toID == "depot" || leg.toID != report.currentID && !report.completedIDs.contains(leg.toID))
        }
    }
    func prepareRouteDraft(legID: String, capture: Data) {
        guard !isBusy else { return }
        routeDraft = nil; routeProposal = nil
        do { perform("routeDraftJSON", [String(decoding: try exportData(), as: UTF8.self), legID, String(decoding: capture, as: UTF8.self)], draftOnly: true) }
        catch { errorMessage = error.localizedDescription }
    }
    func reuseRouteChecks() {
        guard !isBusy, let draft = routeDraft else { return }
        routeProposal = nil
        do { perform("reuseRouteJSON", [String(decoding: try exportData(), as: UTF8.self), try RoadBridge.json(draft), true], draftOnly: true) }
        catch { errorMessage = error.localizedDescription }
    }
    func updateRouteDraft(_ leg: DeliveryLeg) {
        guard !isBusy, routeDraft?.leg.id == leg.id else { return }
        routeDraft?.leg = leg; routeProposal = nil
    }
    func invalidateRoutePreview() { routeProposal = nil }
    func discardRouteDraft() { guard !isBusy else { return }; routeDraft = nil; routeProposal = nil }
    func previewRoute(minute: Int) {
        guard !isBusy, let draft = routeDraft else { return }
        routeProposal = nil
        do { perform("previewRouteJSON", [String(decoding: try exportData(), as: UTF8.self), try RoadBridge.json(draft), minute, UUID().uuidString], proposalOnly: true) }
        catch { errorMessage = error.localizedDescription }
    }
    func commitRoute() {
        guard !isBusy, let proposal = routeProposal else { return }
        let commit = TripRouteCommit(baseBasis: proposal.baseBasis, event: proposal.event)
        do { perform("commitRouteJSON", [String(decoding: try exportData(), as: UTF8.self), try RoadBridge.json(commit)], autoRefresh: true) }
        catch { errorMessage = error.localizedDescription }
    }
    func importTrip(_ url: URL) {
        guard !isBusy else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Self.read(url)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlannerFailure.message("운행 형식을 확인해 주세요.") }
            // Imported forecasts are untrusted; preserve actual events and calculate again.
            object.removeValue(forKey: "guidance")
            let clean = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            _ = try Self.decode(clean)
            perform("inspectJSON", [String(decoding: clean, as: UTF8.self)], archive: true, autoRefresh: true)
        } catch { errorMessage = "운행을 불러오지 못했습니다: \(error.localizedDescription)" }
    }
    private func perform(_ method: String, _ arguments: [Any], archive: Bool = false, comparisonOnly: Bool = false, draftOnly: Bool = false, proposalOnly: Bool = false, autoRefresh: Bool = false, afterSave: ((String?) -> Void)? = nil) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try TripBridge.run(method, arguments) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBusy = false
                switch outcome {
                case .failure(let error): self.errorMessage = error.localizedDescription
                case .success(let output):
                    let envelope = output.envelope
                    do {
                        if comparisonOnly {
                            self.comparison = envelope.comparison
                        } else if draftOnly {
                            self.routeDraft = envelope.routeDraft; self.routeProposal = nil
                        } else if proposalOnly {
                            self.routeProposal = envelope.routeProposal
                        } else {
                            guard let data = output.tripData, let report = envelope.report else { throw PlannerFailure.message("운행 상태가 없습니다.") }
                            let session = try Self.decode(data)
                            if archive { try self.archiveExisting() }
                            try data.write(to: Self.activeURL(), options: .atomic)
                            self.trip = session; self.report = report; self.activeData = data
                            self.forecast = envelope.result; self.drive = envelope.drive; self.comparison = nil
                            self.routeDraft = nil; self.routeProposal = nil
                            self.recoveryRequired = false
                            self.message = envelope.drive?.message ?? "실제 기록을 저장했습니다."
                            afterSave?(envelope.drive?.route?.routeURL)
                            // Save actual events BEFORE potentially lengthy planning.
                            if autoRefresh, report.phase == "ready" { self.replan() }
                        }
                    } catch { self.errorMessage = "기록을 반영하지 못했습니다: \(error.localizedDescription)" }
                }
            }
        }
    }
}
