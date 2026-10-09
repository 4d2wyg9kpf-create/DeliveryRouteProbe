import Foundation
import Combine
import JavaScriptCore

enum PlannerFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

enum PlannerBridge {
    static func run(_ input: Data) throws -> Data {
        guard let context = JSContext(), let json = String(data: input, encoding: .utf8) else {
            throw PlannerFailure.message("계산 엔진을 열지 못했습니다.")
        }
        context.evaluateScript(PlannerEngineSource.source)
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "계산 코드 오류") }
        let value = context.objectForKeyedSubscript("DeliveryPlanner")?.invokeMethod("solveJSON", withArguments: [json])
        if let error = context.exception { throw PlannerFailure.message(error.toString() ?? "계산 오류") }
        guard let text = value?.toString(), let data = text.data(using: .utf8) else {
            throw PlannerFailure.message("계산 결과를 읽지 못했습니다.")
        }
        return data
    }
}

@MainActor
final class PlannerStore: ObservableObject {
    @Published var plan: DeliveryPlan {
        didSet {
            revision += 1
            result = nil
            resultData = nil
            if isComputing { cancelCalculation() }
            queueSave()
        }
    }
    @Published var result: PlannerResult?
    @Published var resultData: Data?
    @Published var isComputing = false
    @Published var message = "거래처와 방향별 이동시간을 등록해 주세요."
    @Published var errorMessage: String?
    @Published var autoSaveEnabled = true
    private var saveWork: DispatchWorkItem?
    private var revision = 0
    private var runID = UUID()

    init() {
        var loaded = DeliveryPlan()
        var failure: String?
        do {
            let url = try Self.planURL()
            if FileManager.default.fileExists(atPath: url.path) {
                loaded = try Self.decode(Data(contentsOf: url))
            }
        } catch { failure = "저장된 계획을 읽지 못해 자동저장을 중지했습니다. 기존 파일은 보존됩니다. \(error.localizedDescription)" }
        plan = loaded
        if let failure = failure { autoSaveEnabled = false; errorMessage = failure }
    }

    private static func planURL() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("RouteProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("delivery-plan.json")
    }

    static func decode(_ data: Data) throws -> DeliveryPlan {
        guard data.count <= 128_000_000 else { throw PlannerFailure.message("계획 파일은 128MB 이하여야 합니다.") }
        var value = try JSONDecoder().decode(DeliveryPlan.self, from: data)
        guard [2, 3].contains(value.schemaVersion), value.visits.count <= 30, value.legs.count <= 5611 else {
            throw PlannerFailure.message("지원하는 계획 형식은 버전 2·3, 거래처 30곳 이하입니다.")
        }
        guard !value.originName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.destination == nil || (value.returnToOrigin && !value.destination!.name.isEmpty) else {
            throw PlannerFailure.message("출발지와 최종 도착지 설정을 확인해 주세요.")
        }
        let ids = value.visits.map(\.id)
        guard Set(ids).count == ids.count, !ids.contains("depot"), !ids.contains("destination"), !ids.contains("") else {
            throw PlannerFailure.message("거래처 식별자가 중복되거나 잘못됐습니다.")
        }
        guard Set(value.legs.map(\.id)).count == value.legs.count,
              value.visits.allSatisfy({ Set($0.orders.map(\.id)).count == $0.orders.count }),
              (0...1439).contains(value.startMinute) else {
            throw PlannerFailure.message("이동 구간·품목 식별자 또는 출발시각이 잘못됐습니다.")
        }
        guard (value.cargo?.columns.count ?? 0) <= 160, (value.cargo?.lots.count ?? 0) <= 600,
              (value.cargo?.pallets.count ?? 0) <= 2 else {
            throw PlannerFailure.message("파렛트 2장, 적재 위치 160개, 배치 묶음 600개 한도를 확인해 주세요.")
        }
        if let cargo = value.cargo {
            guard Set(cargo.columns.map(\.id)).count == cargo.columns.count,
                  Set(cargo.lots.map(\.id)).count == cargo.lots.count,
                  Set(cargo.pallets.map(\.id)).count == cargo.pallets.count,
                  cargo.columns.allSatisfy({ Set($0.supports.map(\.direction)).count == $0.supports.count }) else {
                throw PlannerFailure.message("적재 위치·배치·지지 방향 식별자가 중복됩니다.")
            }
            if let settings = cargo.autoLayout {
                guard settings.transfers.count <= 100, Set(settings.transfers.map(\.id)).count == settings.transfers.count else {
                    throw PlannerFailure.message("매입→배송 연결은 중복 없이 100개까지 등록할 수 있습니다.")
                }
            }
        }
        let counts = Dictionary(grouping: value.legs.filter { $0.source != "tmap" }, by: { [$0.fromID, $0.toID] })
        guard counts.values.allSatisfy({ $0.count <= 6 }) else { throw PlannerFailure.message("방향별 경로 후보는 6개까지 지원합니다.") }
        value.schemaVersion = 3
        if value.cargo == nil { value.cargo = CargoPlan() }
        if value.cargo?.rehandling == nil { value.cargo?.rehandling = CargoRehandlingSettings() }
        for i in value.visits.indices {
            for order in DeliveryOrder.emptyOrders() where !value.visits[i].orders.contains(where: { $0.id == order.id }) {
                value.visits[i].orders.append(order)
            }
        }
        return value
    }

    func planData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(plan)
    }

    private func queueSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        guard autoSaveEnabled else { return }
        do { try planData().write(to: Self.planURL(), options: .atomic) }
        catch { errorMessage = "자동저장 실패: \(error.localizedDescription). 계획 내보내기로 보관해 주세요." }
    }

    func replacePlan(_ value: DeliveryPlan) {
        autoSaveEnabled = true
        errorMessage = nil
        plan = value
        saveNow()
        message = "계획을 불러왔습니다. 계산하면 새 결과가 표시됩니다."
    }

    func importPlan(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { replacePlan(try Self.decode(Data(contentsOf: url))) }
        catch { errorMessage = "계획을 불러오지 못했습니다: \(error.localizedDescription)" }
    }

    func saveVisit(_ visit: DeliveryVisit) {
        guard !visit.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "거래처 이름을 입력해 주세요."; return }
        var next = plan
        if let index = next.visits.firstIndex(where: { $0.id == visit.id }) { next.visits[index] = visit }
        else {
            guard next.visits.count < 30 else { errorMessage = "거래처는 최대 30곳까지 등록할 수 있습니다."; return }
            next.visits.append(visit)
        }
        plan = next
    }

    func removeVisit(_ id: String) {
        guard id != "depot", plan.visits.contains(where: { $0.id == id }) else { return }
        var next = plan
        next.visits.removeAll { $0.id == id }
        next.legs.removeAll { $0.fromID == id || $0.toID == id }
        next.cargo?.lots.removeAll { $0.loadAt == id || $0.unloadAt == id }
        next.cargo?.autoLayout?.transfers.removeAll { $0.fromID == id || $0.toID == id }
        for index in next.visits.indices {
            next.visits[index].afterIDs.removeAll { $0 == id }
            if next.visits[index].immediatelyAfterID == id { next.visits[index].immediatelyAfterID = "" }
        }
        next.tmapBinding = nil
        for index in next.legs.indices where next.legs[index].source == "tmap" { next.legs[index].locationInvalidated = true }
        plan = next
        saveNow()
    }

    func clearOriginLocation() {
        var next = plan
        next.tmapOrigin = nil; next.naverOrigin = nil; next.originAccess = nil; next.originCustomerID = nil; next.tmapBinding = nil
        for index in next.legs.indices where next.legs[index].fromID == "depot" || next.legs[index].toID == "depot" || next.legs[index].source == "tmap" {
            next.legs[index].locationInvalidated = true
        }
        plan = next; saveNow()
    }

    func clearDestination() {
        var next = plan; next.destination = nil; next.tmapBinding = nil
        next.legs.removeAll { $0.fromID == "destination" || $0.toID == "destination" }
        for index in next.legs.indices where next.legs[index].source == "tmap" { next.legs[index].locationInvalidated = true }
        plan = next; saveNow()
    }

    func saveLocation(_ coordinate: TMapCoordinate, id: String) {
        var next = plan
        let previous = TMapBridge.coordinate(next, id: id)
        if id == "depot" { next.tmapOrigin = coordinate }
        else if id == "destination" { next.destination?.tmapCoordinate = coordinate }
        else if let index = next.visits.firstIndex(where: { $0.id == id }) { next.visits[index].tmapCoordinate = coordinate }
        if previous?.longitude != coordinate.longitude || previous?.latitude != coordinate.latitude {
            next.tmapBinding = nil
            if var access = next.access(id) { access.curbConfirmed = false; access.curbEntranceToken = nil; access.bikeEntrance?.entranceConfirmed = false; next.setAccess(access, id: id) }
            for index in next.legs.indices where next.legs[index].fromID == id || next.legs[index].toID == id || next.legs[index].source == "tmap" { next.legs[index].locationInvalidated = true }
        }
        plan = next; saveNow()
    }

    func saveLeg(_ leg: DeliveryLeg) {
        guard leg.fromID != leg.toID, !leg.toID.isEmpty, leg.minutes >= 0 else { errorMessage = "서로 다른 출발·도착 거래처와 이동시간을 입력해 주세요."; return }
        var next = plan
        guard (0...2880).contains(leg.minutes), next.nodes.contains(where: { $0.id == leg.fromID }), next.nodes.contains(where: { $0.id == leg.toID }) else {
            errorMessage = "거래처와 이동시간을 확인해 주세요."; return
        }
        guard next.legs.filter({ $0.fromID == leg.fromID && $0.toID == leg.toID && $0.id != leg.id && (leg.source == "tmap" ? $0.source == "tmap" : $0.source != "tmap") }).count < (leg.source == "tmap" ? 1 : 6) else {
            errorMessage = "같은 방향의 경로 후보는 6개까지 저장할 수 있습니다."; return
        }
        next.legs.removeAll { $0.id == leg.id }
        next.legs.append(leg)
        plan = next
    }

    func removeLeg(_ id: String) { plan.legs.removeAll { $0.id == id } }

    func releaseTMapOrder() {
        var next = plan
        next.tmapBinding = nil
        next.legs.removeAll { $0.source == "tmap" }
        plan = next
        message = "티맵 순서를 해제했습니다. 기존 방문 조건과 이동 구간으로 계산할 수 있습니다."
    }

    func adoptGeneratedCargo() {
        guard var proposed = result?.generatedCargo else { return }
        var settings = plan.cargo?.autoLayout
        settings?.enabled = false
        proposed.autoLayout = settings
        plan.cargo = proposed
        saveNow()
        message = "선택한 배치를 수동 배치로 저장했습니다. 수정한 뒤 다시 계산할 수 있습니다."
    }

    func calculate() {
        guard !isComputing else { return }
        do {
            let input = try planData(), inputRevision = revision, token = UUID()
            runID = token
            isComputing = true
            errorMessage = nil
            result = nil; resultData = nil
            message = plan.cargo?.enabled == true ? (plan.cargo?.autoLayout?.enabled == true ? "주문으로 배치를 만들고 방문 순서·상하차 가능 여부를 비교하고 있습니다." : "방문 순서·시간·상하차 가능 여부를 계산하고 있습니다.") : "방문 순서와 도착·출발 시간을 계산하고 있습니다."
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = Result { () throws -> (PlannerResult, Data) in
                    let data = try PlannerBridge.run(input)
                    return (try JSONDecoder().decode(PlannerResult.self, from: data), data)
                }
                DispatchQueue.main.async {
                    guard let self = self, self.runID == token, self.revision == inputRevision else { return }
                    self.isComputing = false
                    switch outcome {
                    case .success(let pair):
                        self.result = pair.0; self.resultData = pair.1
                        self.message = pair.0.status == "candidate" ? (pair.0.automaticLoading != nil ? "자동 생성한 배치와 방문 순서 후보입니다." : pair.0.loadingValidated ? "등록한 배치의 적재 조건을 반영한 방문 순서입니다." : "선택한 조건의 방문 순서 후보를 계산했습니다. 항목별 확인 상태는 아래에 표시합니다.") : "입력 조건·적재 배치·미등록 이동 구간을 확인해 주세요."
                    case .failure(let error): self.errorMessage = "계산 실패: \(error.localizedDescription)"
                    }
                }
            }
        } catch { errorMessage = "계획을 계산기에 전달하지 못했습니다: \(error.localizedDescription)" }
    }

    func cancelCalculation() {
        runID = UUID()
        isComputing = false
        message = "계산 결과 받기를 취소했습니다. 수정 후 다시 계산해 주세요."
    }
}
