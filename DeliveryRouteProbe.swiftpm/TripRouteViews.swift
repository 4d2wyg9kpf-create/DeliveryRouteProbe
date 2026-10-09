import SwiftUI

struct TripRouteUpdateScreen: View {
    @ObservedObject var store: TripStore
    @ObservedObject var browser: BrowserModel
    let openMap: (String) -> Void
    @EnvironmentObject private var inputs: NativeInputSession
    @State private var fromID = ""
    @State private var toID = ""
    @State private var legID = ""
    @State private var minute = 0
    @State private var editing: DeliveryLeg?
    @State private var initialized = false

    var body: some View {
        Form {
            if let trip = store.trip, let report = store.report, report.phase == "ready" {
                selection(trip.effectivePlan, report)
                if let draft = store.routeDraft { draftSection(draft, trip.effectivePlan) }
                if let proposal = store.routeProposal { previewSection(proposal, trip.effectivePlan, report) }
            } else {
                Text("거래처 작업 완료 후 정차 중에 남은 경로를 갱신합니다.")
            }
            if let error = store.errorMessage { Section { Text(error).foregroundColor(.red).textSelection(.enabled) } }
        }
        .navigationTitle("남은 경로 갱신")
        .disabled(store.isBusy)
        .overlay { if store.isBusy { ProgressView("경로와 일정 확인 중").padding().background(.regularMaterial).cornerRadius(12) } }
        .onAppear {
            if !initialized {
                minute = store.report?.clock ?? 0
                let leg = store.routeDraft?.leg ?? store.routeTargets.first { $0.id == store.drive?.route?.legID } ?? store.routeTargets.first
                fromID = leg?.fromID ?? ""; toID = leg?.toID ?? ""; legID = leg?.id ?? ""; initialized = true
            }
        }
        .onChange(of: fromID) { _, _ in selectDestination() }
        .onChange(of: toID) { _, _ in selectCandidate() }
        .onChange(of: legID) { _, value in
            if let draft = store.routeDraft, draft.leg.id != value { store.discardRouteDraft() }
        }
        .onChange(of: minute) { _, _ in store.invalidateRoutePreview() }
        .onChange(of: store.report?.clock) { _, value in
            if let value = value { minute = max(minute, value) }
        }
        .sheet(item: $editing) { leg in
            if let trip = store.trip {
                RoadLegEditor(leg: leg, plan: trip.effectivePlan, browser: browser, saveTitle: "초안에 반영") { store.updateRouteDraft($0) }
            }
        }
    }

    private func selection(_ plan: DeliveryPlan, _ report: TripReport) -> some View {
        let targets = store.routeTargets
        let destinations = Set(targets.filter { $0.fromID == fromID }.map(\.toID))
        let candidates = targets.filter { $0.fromID == fromID && $0.toID == toID }
        return Section("갱신할 구간") {
            Picker("출발 거래처", selection: $fromID) {
                ForEach(plan.nodes.filter { node in targets.contains { $0.fromID == node.id } }, id: \.id) { node in
                    Text(plan.name(node.id) + (node.id == report.currentID ? " · 현재 위치" : "")).tag(node.id)
                }
            }
            Picker("도착 거래처", selection: $toID) {
                ForEach(plan.nodes.filter { destinations.contains($0.id) }, id: \.id) { node in Text(node.name).tag(node.id) }
            }
            Picker("바꿀 경로 후보", selection: $legID) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, leg in
                    Text("\(index + 1). \(leg.routeLabel ?? "등록 경로") · \(leg.minutes)분").tag(leg.id)
                }
            }
            Button("이 구간을 네이버에서 열기") {
                inputs.finishEditing()
                do {
                    let request = try RoadBridge.request(plan, from: fromID, to: toID)
                    if request.ok, let url = request.url { openMap(url) }
                    else { store.errorMessage = request.errors.joined(separator: "\n") }
                } catch { store.errorMessage = error.localizedDescription }
            }.disabled(legID.isEmpty)
            Text("지도에서 자동차 후보의 상세 안내를 읽은 뒤 돌아오세요. 같은 출발·경유·도착 지점인 자료만 가져옵니다.").font(.caption)
            Button("마지막으로 읽은 자동차 경로 가져오기") {
                inputs.finishEditing()
                if let data = browser.exportData { store.prepareRouteDraft(legID: legID, capture: data) }
            }.disabled(legID.isEmpty || browser.exportData == nil || browser.bikeCapture != nil)
            if let time = browser.capture?.capturedAt { Text("마지막 판독: " + time).font(.caption).foregroundColor(.secondary) }
            Text(store.message).font(.caption).foregroundColor(.secondary)
        }
    }

    private func draftSection(_ draft: TripRouteDraft, _ plan: DeliveryPlan) -> some View {
        Section("반영 전 경로 확인") {
            Text("\(plan.name(draft.leg.fromID)) → \(plan.name(draft.leg.toID))").bold()
            Text("이동시간 \(draft.previousMinutes)분 → \(draft.leg.minutes)분")
            if let date = draft.leg.capturedAt { Text("새 자료 판독: " + date).font(.caption) }
            if let date = draft.previousCapturedAt { Text("이전 자료 판독: " + date).font(.caption).foregroundColor(.secondary) }
            Text(draft.sameGuides ? "지점·전체 거리·상세 안내가 이전과 같습니다. 지도 선형까지 같은지는 확인이 필요합니다." : "이전과 다른 경로입니다. 높이·방향·1종 요금을 새 경로에 맞춰 확인하세요.").font(.caption)
            Button("높이·출발·도착 방향·1종 요금 확인") { editing = draft.leg }
            if draft.sameGuides {
                Button("지도에서도 같은 경로임 · 이전 확인 연결") { store.reuseRouteChecks() }
                Text("네이버 높이 설정은 새 판독 자료에서 확인합니다. 연결된 이전 1종 요금의 판독 시각은 유지합니다.").font(.caption).foregroundColor(.secondary)
            }
            if draft.reusedChecks { Text("이전 확인 내용을 연결했습니다.").font(.caption) }
            if let fare = draft.leg.road?.class1TollWon {
                Text("연결된 1종 통행료 \(fare)원")
                if let date = fareDate(draft.leg) { Text("요금 판독: " + date).font(.caption) }
            }
            Text("조건 확인 화면의 저장은 이 초안에만 반영합니다. 다른 경로의 요금은 지도에서 1종 상세를 읽은 뒤 확인 화면에서 연결하세요.").font(.caption)
            TripMinutePicker(title: "갱신 기록 시각", minute: $minute)
            Button("현재 시각 넣기") { minute = currentMinute(plan.planDate) }
            Button("변경 후 남은 일정 미리 계산") { inputs.finishEditing(); store.previewRoute(minute: minute) }
                .disabled(minute < (store.report?.clock ?? 0))
            Button("이 초안 버리기", role: .destructive) { store.discardRouteDraft() }
        }
    }

    private func previewSection(_ proposal: TripRouteProposal, _ plan: DeliveryPlan, _ report: TripReport) -> some View {
        Section("반영하면 바뀌는 일정") {
            if let before = proposal.beforeFinishMinute { Text("반영 전 복귀 예상 \(PlannerClock.text(before))") }
            if let result = proposal.result, proposal.hasCandidate {
                if let finish = result.finishMinute { Text("반영 후 복귀 예상 \(PlannerClock.text(finish))").bold() }
                if let rest = result.rest { Text("휴식 \(PlannerClock.text(rest.startMinute))~\(PlannerClock.text(rest.endMinute)) · \(plan.name(rest.visitID))") }
                ForEach(result.rows) { row in
                    Text("\(row.position). \(plan.name(row.visitID)) · 도착 \(PlannerClock.text(row.arrivalMinute)) · 작업완료 \(PlannerClock.text(row.readyMinute))").font(.caption)
                }
                if let cargo = result.cargo {
                    let cargoPlan = withCurrentCargo(plan, report)
                    NavigationLink("이 순서의 화물·재배치 확인") { CargoResultView(plan: cargoPlan, result: cargo) }
                }
            }
            ForEach(Array(proposal.messages.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
            Text("반영하면 갱신 이력을 먼저 저장하고 남은 일정을 계산합니다. 완료한 거래처와 실제 화물 위치·수량은 유지됩니다.").font(.caption)
            Button(proposal.hasCandidate ? "경로 변경을 운행에 반영" : "변경 자료 저장 · 기존 일정 출발 중지") { store.commitRoute() }
                .disabled(proposal.event.minute != minute)
        }
    }

    private func selectDestination() {
        let legs = store.routeTargets.filter { $0.fromID == fromID }
        if !legs.contains(where: { $0.toID == toID }) { toID = legs.first?.toID ?? "" }
        selectCandidate()
    }
    private func selectCandidate() {
        let legs = store.routeTargets.filter { $0.fromID == fromID && $0.toID == toID }
        if !legs.contains(where: { $0.id == legID }) { legID = legs.first?.id ?? "" }
    }
    private func withCurrentCargo(_ plan: DeliveryPlan, _ report: TripReport) -> DeliveryPlan {
        var result = plan; result.cargo = report.cargoConfig; return result
    }
    private func fareDate(_ leg: DeliveryLeg) -> String? {
        let json = leg.road?.fareSource == "naverClass1" ? leg.captureJSON : leg.road?.fareCaptureJSON
        guard let data = json?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["capturedAt"] as? String
    }
    private func currentMinute(_ planDate: String) -> Int {
        let calendar = Calendar.current, formatter = DateFormatter()
        formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let now = Date(), date = formatter.date(from: planDate) ?? now
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return min(4319, max(store.report?.clock ?? 0, days * 1440 + (parts.hour ?? 0) * 60 + (parts.minute ?? 0)))
    }
}
