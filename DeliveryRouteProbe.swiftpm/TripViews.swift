import SwiftUI
import UniformTypeIdentifiers

struct TripScreen: View {
    @ObservedObject var store: TripStore
    @ObservedObject var planner: PlannerStore
    @ObservedObject var browser: BrowserModel
    let openMap: (String) -> Void
    @EnvironmentObject private var inputs: NativeInputSession
    @State private var minute = 480
    @State private var departureMinute = 480
    @State private var workMinutes = 5
    @State private var restMinutes = 60
    @State private var priorityID = ""
    @State private var acknowledgeVariance = false
    @State private var showWork = false
    @State private var showTarget = false
    @State private var columnDraft: CargoColumn?
    @State private var showExport = false
    @State private var showImport = false
    @State private var confirmImport = false
    @State private var confirmUndo = false
    @State private var document = CaptureDocument()

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if let trip = store.trip, let report = store.report {
                    activeSections(trip, report)
                    if report.phase == "returned", !report.hasCargo { startSection }
                } else { startSection }
            }
            .navigationTitle("운행 안내")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("현재 운행 내보내기") {
                            do { document = CaptureDocument(data: try store.exportData()); showExport = true }
                            catch { store.errorMessage = error.localizedDescription }
                        }.disabled(store.trip == nil)
                        Button("운행 기록 가져오기") { confirmImport = true }
                        Button("마지막 실제 기록 되돌리기") { confirmUndo = true }
                            .disabled((store.trip?.events.count ?? 0) < 2)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(store.isBusy)
                }
            }
            .disabled(store.isBusy)
            .overlay { if store.isBusy { ProgressView("운행 상태 확인 중").padding().background(.regularMaterial).cornerRadius(12) } }
            .onAppear { syncInputs(); departureMinute = planner.plan.startMinute; store.resumeGuidanceIfNeeded() }
            .onChange(of: store.trip?.events.last?.id) { _, _ in syncInputs() }
            .sheet(isPresented: $showWork) {
                if let trip = store.trip, let report = store.report {
                    TripWorkEditor(plan: trip.plan, report: report, initialMinute: minute) { store.record($0) }
                }
            }
            .sheet(isPresented: $showTarget) {
                if let trip = store.trip, let report = store.report {
                    TripTargetEditor(plan: trip.plan, report: report, minute: minute) { store.record($0) }
                }
            }
            .sheet(item: $columnDraft) { draft in
                if let report = store.report {
                    CargoColumnEditor(draft: draft, config: report.cargoConfig) { column in
                        var event = TripEvent(type: "addPosition", minute: minute); event.column = column
                        store.record(event)
                    }
                }
            }
            .confirmationDialog("마지막 기록을 취소하고 바로 전 상태로 돌아갑니다. 취소 이력은 남습니다.", isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("마지막 기록 되돌리기", role: .destructive) { store.record(TripEvent(type: "undo", minute: store.report?.clock ?? minute)) }
            }
            .confirmationDialog("가져온 운행을 현재 운행으로 엽니다. 기존 운행은 별도 기록으로 보관합니다.", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("파일 선택") { showImport = true }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): store.importTrip(url); case .failure(let error): store.errorMessage = error.localizedDescription }
            }
            .fileExporter(isPresented: $showExport, document: document, contentType: .json, defaultFilename: "배송운행_기록") { result in
                if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
            }
        }
    }

    private var statusSection: some View {
        Section {
            Text(store.message).font(.subheadline)
            if let error = store.errorMessage { Text(error).foregroundColor(.red).textSelection(.enabled) }
            TripMinutePicker(title: "기록 시각", minute: $minute)
            Button("현재 시각 넣기") { inputs.finishEditing(); minute = actualNow() }
            Text("도착·상하차·이동은 실제로 수행한 뒤 기록합니다. 계산 결과만으로 차량 재고를 바꾸지 않습니다.").font(.caption).foregroundColor(.secondary)
        }
    }
    private var startSection: some View {
        Section("출발") {
            Text("\(planner.plan.originName)에서 출발 · 최종 도착: \(planner.plan.finishName)")
            if let result = planner.result, result.status == "candidate", result.loadingValidated, let data = planner.resultData {
                Text("\(planner.plan.planDate) · 최신 계산 결과 · \(result.rows.count)곳")
                TripMinutePicker(title: "이 운행의 실제 출발", minute: $departureMinute)
                Text("선택한 배치대로 실었는지 확인하세요. 실제 출발 시각으로 일정을 다시 계산하되 실은 배치는 유지합니다. 출발 기록을 저장한 뒤 등록된 네이버 경로를 엽니다.").font(.caption)
                Button("이 배치로 실었음 · 출발 및 경로 열기") {
                    inputs.finishEditing(); store.start(plan: planner.plan, resultData: data, minute: departureMinute) { url in
                        if let url = url { openMap(url) }
                    }
                }.disabled(departureMinute > 1439)
            } else {
                Text("배송계획에서 적재 조건을 켜고 계산을 마치면 출발할 수 있습니다.").foregroundColor(.secondary)
            }
        }
    }
    @ViewBuilder private func activeSections(_ trip: TripSession, _ report: TripReport) -> some View {
        Section(report.phaseLabel) {
            Text("\(trip.plan.planDate) · 출발 \(PlannerClock.text(report.originDepartureMinute))")
            Text("완료 \(report.completedIDs.count)/\(trip.plan.visits.count)곳 · 기록 시각 \(PlannerClock.text(report.clock))").font(.caption)
            if let transit = report.transit {
                Text("\(trip.plan.name(transit.fromID)) → \(trip.plan.name(transit.toID))").bold()
                Button("실제 도착 기록") { record("arrive") }
            } else {
                Text(trip.plan.name(report.currentID)).bold()
            }
            Text(report.restTaken ? "11~13시 시작 연속 60분 휴식 기록됨" : "해당 시간대 연속 60분 휴식 기록 없음").font(.caption)
        }
        if let drive = store.drive {
            guidance(drive, report)
            if !drive.upcoming.isEmpty || drive.finishMinute != nil { DriveScheduleSection(drive: drive, plan: trip.plan) }
        }
        if report.phase == "atStop" { customerWork(trip, report) }
        if report.isStopped {
            Section("순서 변경·빈자리 활용") {
                Picker("바로 다음에 갈 거래처", selection: $priorityID) {
                    Text("최적 순서에 맡김").tag("")
                    ForEach(trip.plan.visits.filter { !report.completedIDs.contains($0.id) && $0.id != report.currentID }) { Text($0.name).tag($0.id) }
                }
                Button("다음 방문 지정 반영") { var event = TripEvent(type: "urgent", minute: minute); event.toID = priorityID; store.record(event) }
                Button("화물 직접 옮기기·수량 기록") { showWork = true }
                Button("재배치할 빈자리 추가") {
                    var column = CargoColumn(); column.name = "재배치 자리 \(report.cargoConfig.columns.count + 1)"
                    column.palletID = report.cargoConfig.pallets.first?.id ?? ""
                    columnDraft = column
                }.disabled(report.cargoConfig.columns.count >= 160)
                Button("남은 주문 수량 변경") { showTarget = true }
                Text("고정 순번·선행 조건은 유지합니다. C를 먼저 가려면 B 물량을 옮길 공간과 작업시간까지 남은 경로 계산에 반영합니다.").font(.caption)
            }
            Section("실제 휴식·대기") {
                HStack { Text("실제 휴식 시간(분)"); IntegerInput(title: "휴식 시간", value: $restMinutes) }
                Text("\(PlannerClock.text(minute))~\(PlannerClock.text(min(4319, minute + min(4319, max(0, restMinutes)))))")
                Button("위 시간 동안 쉰 것으로 기록") {
                    var event = TripEvent(type: "rest", minute: minute); event.endMinute = minute + restMinutes; store.record(event)
                }.disabled(restMinutes < 1 || restMinutes > 4319 || minute + min(4319, max(0, restMinutes)) > 4319)
                Button("작업 없이 이 시각까지 대기 기록") { record("clock") }
                Text("휴식은 다른 작업과 겹칠 수 없습니다. 11~13시 시작·연속 60분 이상일 때 해당 휴식으로 인정합니다.").font(.caption)
            }
        }
        if report.phase == "ready" { nextRoute(trip, report) }
        if report.phase == "returned", report.hasCargo {
            Section("최종 도착지에서 남은 화물 내리기") {
                Text("복귀 시 재고를 자동으로 0으로 만들지 않습니다.").font(.caption)
                Button("실제 하차·재배치 기록") { showWork = true }
            }
        }
        inventory(trip, report)
        if !report.warnings.isEmpty {
            Section("계획과 달랐던 실제 기록") { ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).foregroundColor(.orange) } }
        }
        Section("최근 기록") {
            ForEach(Array(trip.events.suffix(20).reversed())) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(PlannerClock.text(event.minute)) · \(event.label)")
                    if let end = event.endMinute { Text("종료 \(PlannerClock.text(end))").font(.caption) }
                    if let actions = event.actions { ForEach(Array(actions.enumerated()), id: \.offset) { _, action in Text(CargoActionText.text(action, config: report.cargoConfig)).font(.caption) } }
                    if let to = event.toID { Text(to.isEmpty ? "다음 방문 지정 해제" : trip.plan.name(to)).font(.caption) }
                    if let note = event.note { Text(note).font(.caption) }
                    if event.type == "routeUpdate", let update = event.routeUpdate {
                        Text("\(trip.plan.name(update.leg.fromID)) → \(trip.plan.name(update.leg.toID)) · \(update.previousMinutes)분 → \(update.leg.minutes)분").font(.caption)
                        if let date = update.leg.capturedAt { Text("경로 판독: " + date).font(.caption) }
                    }
                }
            }
            Text("전체 기록과 취소 이력은 운행 내보내기에 포함됩니다.").font(.caption).foregroundColor(.secondary)
        }
    }
    @ViewBuilder private func guidance(_ drive: DriveStatus, _ report: TripReport) -> some View {
        if let route = drive.route {
            Section(report.phase == "atStop" ? "현재 거래처 안내" : "다음 목적지 안내") {
                DriveRouteSummary(route: route, arrived: report.phase == "atStop")
                if report.phase == "ready" {
                    if let departure = route.departureMinute {
                        Text("출발 예정 \(PlannerClock.text(departure))").bold()
                        if minute < departure { Text("대기나 휴식을 마친 뒤 실제 시각을 기록해 주세요.").font(.caption) }
                        if minute > departure {
                            Button("선택 시각까지 대기 기록하고 일정 갱신") { record("clock") }
                        }
                    }
                    if !drive.departureIssue.isEmpty { Text(drive.departureIssue).font(.caption).foregroundColor(.orange) }
                    Button(route.routeURL == nil ? "다음 장소로 실제 출발 기록" : "출발 기록하고 네이버 경로 열기") {
                        inputs.finishEditing(); store.depart(minute: minute) { url in
                            if let url = url { openMap(url) }
                        }
                    }.disabled(!drive.canDepart || minute != route.departureMinute)
                } else if report.phase == "driving", let url = route.routeURL {
                    Button("네이버 경로 다시 열기") { openMap(url) }
                }
                if report.phase == "atStop", let start = drive.workNotBefore, start > report.clock {
                    Text("현재 시간 조건으로 작업 시작 가능: \(PlannerClock.text(start))").font(.caption).foregroundColor(.orange)
                }
                if route.routeURL != nil {
                    Text("네이버 화면을 다시 열면 경로가 달라질 수 있습니다. 높이 설정과 상세 경로를 확인하세요.").font(.caption).foregroundColor(.secondary)
                    Button("마지막으로 읽은 자동차 경로와 비교") {
                        if let data = browser.exportData { store.compare(capture: data) }
                    }.disabled(browser.exportData == nil || browser.bikeCapture != nil)
                    if let comparison = store.comparison, comparison.legID == route.legID {
                        DriveComparisonView(comparison: comparison)
                    }
                }
            }
        }
    }
    private func customerWork(_ trip: TripSession, _ report: TripReport) -> some View {
        Section("거래처 실제 작업") {
            ForEach(report.variance.filter { $0.visitID == report.currentID }) { line in
                Text("\(CargoKind.label(line.kind)) · \(line.operation == "load" ? "매입" : "배송") 예정 \(line.planned) / 실제 \(line.actual)").font(.subheadline)
            }
            if !report.suggestionMessage.isEmpty { Text(report.suggestionMessage).font(.caption).foregroundColor(.orange) }
            if !report.suggestedActions.isEmpty {
                DisclosureGroup("남은 상하차·재배치 작업 순서") {
                    ForEach(Array(report.suggestedActions.enumerated()), id: \.offset) { index, action in
                        Text("\(index + 1). \(CargoActionText.text(action, config: report.cargoConfig))").font(.caption)
                    }
                    Text("재배치 예상 추가 \(report.suggestedHandlingMinutes)분").font(.caption)
                }
                HStack { Text("실제로 걸린 작업시간(분)"); IntegerInput(title: "작업 시간", value: $workMinutes) }
                Button("제시한 순서대로 작업했음 · 실제 기록") {
                    inputs.finishEditing(); var event = TripEvent(type: "work", minute: minute)
                    event.endMinute = minute + workMinutes; event.actions = report.suggestedActions; store.record(event)
                }.disabled(workMinutes < 0 || workMinutes > 1440 || minute + min(1440, max(0, workMinutes)) > 4319)
            }
            Button("일부 수량만 상하차·직접 재배치") { showWork = true }
            Toggle("주문과 다른 실제 수량을 확인함", isOn: $acknowledgeVariance)
            Button("이 거래처 작업 완료") {
                inputs.finishEditing(); var event = TripEvent(type: "complete", minute: minute); event.allowVariance = acknowledgeVariance; store.record(event)
            }
            Text("수량이 다르면 확인이 필요합니다. 남은 화물은 차량에 보존되며 이후 배송 가능 여부를 다시 계산합니다.").font(.caption).foregroundColor(.secondary)
        }
    }
    private func nextRoute(_ trip: TripSession, _ report: TripReport) -> some View {
        Section("남은 경로") {
            if !report.departureIssue.isEmpty { Text(report.departureIssue).foregroundColor(.orange) }
            NavigationLink("네이버 경로·이동시간 갱신") {
                TripRouteUpdateScreen(store: store, browser: browser, openMap: openMap)
            }
            Button("현재 화물·시각으로 남은 경로 재계산") { inputs.finishEditing(); store.replan() }.disabled(!report.canDepart)
            Text("계산 기준은 마지막 저장 시각 \(PlannerClock.text(report.clock))입니다. 시간이 지났으면 위에서 대기 시각을 기록하세요.").font(.caption)
            if let forecast = store.forecast {
                ForEach(Array(forecast.messages.enumerated()), id: \.offset) { _, message in Text(message).font(.caption).foregroundColor(.secondary) }
                if forecast.status == "candidate" {
                    if let cargo = forecast.cargo {
                        NavigationLink("방문별 예상 화물·작업 순서") {
                            CargoResultView(plan: currentPlan(trip, report), result: cargo)
                        }
                    }
                }
            }
            Button("현재 거래처 작업 다시 열기") { record("reopen") }
        }
    }
    private func inventory(_ trip: TripSession, _ report: TripReport) -> some View {
        Section("실제 차량 재고·현재 위치") {
            CargoFloorMap(config: report.cargoConfig, snapshot: report.snapshot).frame(height: 300)
            ForEach(report.snapshot.inventory.filter { $0.quantity > 0 }) { item in Text("\(CargoKind.label(item.kind)) \(item.quantity)개") }
            ForEach(report.snapshot.columns.filter { $0.quantity > 0 }) { column in
                DisclosureGroup("\(column.name) · \(column.quantity)개 · 아래 → 위") {
                    ForEach(Array(column.lots.enumerated()), id: \.offset) { _, lot in Text("\(CargoKind.label(lot.kind)) \(lot.quantity)개 → \(trip.plan.name(lot.unloadAt))").font(.caption) }
                }
            }
        }
    }
    private func currentPlan(_ trip: TripSession, _ report: TripReport) -> DeliveryPlan { var plan = trip.effectivePlan; plan.cargo = report.cargoConfig; return plan }
    private func record(_ type: String) { inputs.finishEditing(); store.record(TripEvent(type: type, minute: minute)) }
    private func syncInputs() {
        minute = store.report?.clock ?? planner.plan.startMinute
        priorityID = store.report?.priorityNextID ?? ""; acknowledgeVariance = false
        if let report = store.report { workMinutes = (store.trip?.plan.visits.first { $0.id == report.currentID }?.serviceMinutes ?? 5) + report.suggestedHandlingMinutes }
    }
    private func actualNow() -> Int {
        let calendar = Calendar.current, format = DateFormatter()
        format.calendar = calendar; format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        let today = Date(), date = format.date(from: store.trip?.plan.planDate ?? planner.plan.planDate) ?? today
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: today)).day ?? 0
        let parts = calendar.dateComponents([.hour, .minute], from: today)
        return min(4319, max(store.report?.clock ?? 0, days * 1440 + (parts.hour ?? 0) * 60 + (parts.minute ?? 0)))
    }
}

struct TripMinutePicker: View {
    let title: String
    @Binding var minute: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text(title + " · " + PlannerClock.text(minute)).font(.subheadline)
            HStack {
                Picker("날짜", selection: Binding(get: { minute / 1440 }, set: { minute = $0 * 1440 + minute % 1440 })) {
                    Text("운행일").tag(0); Text("다음 날").tag(1); Text("2일 뒤").tag(2)
                }
                Picker("시", selection: Binding(get: { minute % 1440 / 60 }, set: { minute = minute / 1440 * 1440 + $0 * 60 + minute % 60 })) {
                    ForEach(0..<24) { Text(String(format: "%02d시", $0)).tag($0) }
                }
                Picker("분", selection: Binding(get: { minute % 60 }, set: { minute = minute / 60 * 60 + $0 })) {
                    ForEach(0..<60) { Text(String(format: "%02d분", $0)).tag($0) }
                }
            }.pickerStyle(.menu)
        }
    }
}
