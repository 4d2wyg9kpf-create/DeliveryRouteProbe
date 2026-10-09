import SwiftUI
import Foundation
import UniformTypeIdentifiers

private struct CaptureImportDraft: Identifiable {
    let id = UUID()
    let capture: RouteCapture
    let data: Data
}

struct PlannerScreen: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject var store: PlannerStore
    @ObservedObject var browser: BrowserModel
    let openRoute: (String) -> Void
    @State private var section = 0
    @State private var visitDraft: DeliveryVisit?
    @State private var legDraft: DeliveryLeg?
    @State private var roadLegDraft: DeliveryLeg?
    @State private var captureDraft: CaptureImportDraft?
    @State private var selectedFrom = "depot"
    @State private var showExport = false
    @State private var preparingInputDiagnostics = false
    @State private var exportDocument = CaptureDocument()
    @State private var exportName = "배송계획"
    @State private var showImport = false
    @State private var confirmImport = false
    @State private var demoCount = 6
    @State private var confirmDemo = false
    @State private var cargoExample = "rice100"
    @State private var confirmCargoExample = false
    @State private var deletingVisit: DeliveryVisit?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("거래처 \(store.plan.visits.count)/30 · 구간 \(store.plan.legs.count)개").font(.subheadline)
                    Spacer()
                    if store.isComputing {
                        ProgressView()
                        Button("취소", action: store.cancelCalculation)
                    } else {
                        Button("순서 계산") { inputs.finishEditing(); store.calculate() }.buttonStyle(.borderedProminent)
                    }
                }.padding(.horizontal).padding(.vertical, 8)
                Picker("화면", selection: $section) {
                    Text("운행").tag(0); Text("거래처").tag(1)
                    Text("이동 구간").tag(2); Text("하역·도로").tag(5); Text("적재").tag(4); Text("계산 결과").tag(3)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red).padding(8)
                }
                Group {
                    switch section {
                    case 0: settings
                    case 1: visits
                    case 2: legs
                    case 5: RoadSettingsView(store: store, browser: browser, openRoute: openRoute)
                    case 4: CargoSettingsView(config: Binding(get: { store.plan.cargo ?? CargoPlan() }, set: { store.plan.cargo = $0 }), visits: store.plan.visits)
                    default: results
                    }
                }
            }
            .navigationTitle("배송계획 \(DeliveryAppInfo.version)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("계획 내보내기") { exportPlan() }.disabled(preparingInputDiagnostics)
                        Button("계산 결과 내보내기") { exportResult() }.disabled(store.resultData == nil || preparingInputDiagnostics)
                        Button("계획 불러오기") { confirmImport = true }
                        Button("6곳 예제") { demoCount = 6; confirmDemo = true }
                        Button("30곳 예제") { demoCount = 30; confirmDemo = true }
                        Button("쌀 100포·30포 매입 예제") { cargoExample = "rice100"; confirmCargoExample = true }
                        Button("계란 지지 순서 예제") { cargoExample = "eggs"; confirmCargoExample = true }
                        Button("자동 배치 · 쌀 배송·매입") { cargoExample = "autoRice"; confirmCargoExample = true }
                        Button("자동 배치 · 쌀·계란·박스") { cargoExample = "autoMixed"; confirmCargoExample = true }
                        Button("자동 배치 · 30곳") { cargoExample = "auto30"; confirmCargoExample = true }
                        Divider()
                        Button(preparingInputDiagnostics ? "진단 준비 중…" : "입력 진단 내보내기") {
                            exportInputDiagnostics()
                        }.disabled(preparingInputDiagnostics)
                    } label: { Label("파일·예제", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(item: $visitDraft) { visit in
                VisitEditor(visit: visit, otherVisits: store.plan.visits.filter { $0.id != visit.id }, onSave: store.saveVisit)
            }
            .sheet(item: $legDraft) { leg in
                LegEditor(leg: leg, plan: store.plan, onSave: store.saveLeg)
            }
            .sheet(item: $roadLegDraft) { leg in
                RoadLegEditor(leg: leg, plan: store.plan, browser: browser, onSave: store.saveLeg)
            }
            .sheet(item: $captureDraft) { draft in
                CaptureLegEditor(capture: draft.capture, data: draft.data, plan: store.plan, onSave: store.saveLeg)
            }
            .confirmationDialog("현재 입력을 \(demoCount)곳 가상 예제로 바꿉니다. 보관하려면 먼저 계획을 내보내세요.", isPresented: $confirmDemo, titleVisibility: .visible) {
                Button("예제로 바꾸기", role: .destructive) { store.replacePlan(.demo(count: demoCount)); section = 1 }
            }
            .confirmationDialog("현재 입력을 적재 시험용 가상 예제로 바꿉니다. 치수·거래처·이동시간은 실제 자료가 아닙니다.", isPresented: $confirmCargoExample, titleVisibility: .visible) {
                Button("적재 예제로 바꾸기", role: .destructive) {
                    do { store.replacePlan(try CargoExamples.load(cargoExample)); section = 4 }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
            .confirmationDialog("불러온 계획으로 현재 입력을 바꿉니다. 보관하려면 먼저 계획을 내보내세요.", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("계획 파일 선택") { showImport = true }
            }
            .confirmationDialog("이 거래처와 연결된 이동 구간·선후 조건·화물 배치를 삭제합니다.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("거래처 삭제", role: .destructive) {
                    if let visit = deletingVisit { store.removeVisit(visit.id) }
                    deletingVisit = nil
                }
            }
            .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json, defaultFilename: exportName) { result in
                if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { store.importPlan(url); selectedFrom = "depot" }
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
            }
            .onChange(of: store.result?.status) { value in if value != nil { section = 3 } }
            .onChange(of: store.plan.visits.map(\.id)) { ids in
                if selectedFrom != "depot" && !ids.contains(selectedFrom) { selectedFrom = "depot" }
            }
        }
    }

    private var settings: some View {
        Form {
            Section("출발과 종료") {
                NativeTextField("운행 날짜 YYYY-MM-DD", text: $store.plan.planDate, keyboard: .numbersAndPunctuation)
                    .frame(minHeight: 44)
                Text("출발·최종 도착: 맑은아침농산").bold()
                Picker("출발 시", selection: Binding(get: { store.plan.startMinute/60 }, set: { store.plan.startMinute = $0*60 + store.plan.startMinute%60 })) {
                    ForEach(0..<24) { Text("\($0)시").tag($0) }
                }
                Picker("출발 분", selection: Binding(get: { store.plan.startMinute%60 }, set: { store.plan.startMinute = store.plan.startMinute/60*60 + $0 })) {
                    ForEach(0..<60) { Text("\($0)분").tag($0) }
                }
                NumberRow(title: "회사에서 출발을 늦출 수 있는 한도(분)", value: $store.plan.originWaitMinutes)
                Text("마지막 거래처에서 회사로 돌아오는 이동시간까지 계산합니다.").font(.caption)
            }
            Section("시간 계산 기준") {
                Text("거래처에 일찍 도착해 대기하는 일정도 비교합니다. 조기 도착을 허용하면 시간 구간은 작업 시작에 적용하고, 허용하지 않으면 실제 도착과 작업 시작을 같은 시각으로 계산합니다. 회피 구간에는 도착·작업 시작을 하지 않습니다.")
                Text("기본 체류시간에 조기 도착 대기, 별도 허용한 추가 대기, 휴식을 구분해서 더합니다. 시간 구간의 양 끝은 포함하며 회피 끝 시각은 허용합니다. 다음 날은 24:00 이상으로 입력합니다.")
            }.font(.caption)
            Section("1시간 휴식") {
                Text("실제 회사 출발이 11시 전이고 회사 복귀가 13시 전에 끝나지 않으면, 11~13시에 시작하는 연속 60분 휴식을 넣습니다. 휴식은 늦어도 14시에 끝납니다.")
                Text("휴식 가능으로 표시한 거래처에서만 배치합니다. 작업 전 대기시간에 쉴 수 있으면 그 60분을 중복해서 더하지 않습니다. 마지막 거래처에서 회사로 돌아오는 구간도 휴식 필요 여부와 완료시각에 포함합니다.")
            }.font(.caption)
            Section("계산 범위") {
                Text("저장한 구간 이동시간으로 한 차량의 방문 순서를 계산합니다. 미등록 구간은 사용할 수 없습니다. 네이버 저장값은 미래 교통정보가 아니며, 경로·교통 상황이 바뀌면 갱신이 필요합니다.")
                Text("적재 화면에서 실측 치수·위치·쌓임·통로·지지를 등록하고 적재 조건 반영을 켤 수 있습니다. 등록한 배치에서 상하차할 수 없는 방문 순서는 제외합니다.")
            }.font(.caption)
        }
    }

    private var visits: some View {
        List {
            Button { visitDraft = DeliveryVisit() } label: { Label("거래처 추가", systemImage: "plus") }
                .disabled(store.plan.visits.count >= 30)
            Button("네이버 검색에서 거래처 가져오기") { inputs.finishEditing(); openRoute("https://map.naver.com/p/") }
            Button("네이버 저장 목록에서 거래처 가져오기") { inputs.finishEditing(); openRoute("https://map.naver.com/p/favorite") }
            ForEach(store.plan.visits) { visit in
                Button { visitDraft = visit } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(visit.name).font(.headline)
                        if let place = visit.naverPlace, !place.preferredAddress.isEmpty { Text(place.preferredAddress).font(.caption).foregroundColor(.secondary) }
                        Text("\(visit.kindLabel) · 체류 \(visit.serviceMinutes)분" + (visit.fixedPosition > 0 ? " · \(visit.fixedPosition)번째 고정" : ""))
                            .font(.caption).foregroundColor(.secondary)
                        if !visit.arrivalWindowsText.isEmpty { Text("\(visit.allowEarlyArrival ? "작업 시작" : "도착"): \(visit.arrivalWindowsText)").font(.caption) }
                        if !visit.orderSummary.isEmpty { Text(visit.orderSummary).font(.caption).foregroundColor(.secondary) }
                    }.foregroundColor(.primary)
                }
                .swipeActions {
                    Button("삭제", role: .destructive) { deletingVisit = visit; confirmDelete = true }
                }
            }
            if store.plan.visits.isEmpty { Text("거래처를 등록하거나 우측 위 메뉴에서 가상 예제를 열어 계산을 시험할 수 있습니다.").foregroundColor(.secondary) }
        }
    }

    private var legs: some View {
        List {
            Section {
                Button {
                    if let capture = browser.capture, let data = browser.exportData {
                        captureDraft = CaptureImportDraft(capture: capture, data: data)
                    }
                } label: { Label("마지막으로 읽은 네이버 경로 연결", systemImage: "link") }
                    .disabled(browser.capture == nil || store.plan.visits.isEmpty)
                Button {
                    var leg = DeliveryLeg(); leg.fromID = selectedFrom
                    leg.toID = store.plan.nodes.first(where: { $0.id != selectedFrom })?.id ?? ""
                    legDraft = leg
                } label: { Label("이동시간 직접 등록", systemImage: "plus") }
                    .disabled(store.plan.visits.isEmpty)
                Text("A→B와 B→A는 서로 다른 구간입니다. 같은 방향에 최대 6개 후보를 저장하고 시간·도로 조건에 맞는 후보를 고릅니다. 모든 조합을 채울 필요는 없지만 계산은 등록한 구간만 사용합니다.").font(.caption).foregroundColor(.secondary)
            }
            Section {
                Picker("출발 거래처", selection: $selectedFrom) {
                    ForEach(store.plan.nodes, id: \.id) { node in Text(node.name).tag(node.id) }
                }
                ForEach(store.plan.legs.filter { $0.fromID == selectedFrom }) { leg in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { if leg.source == "naver" || leg.source == "tmap" { roadLegDraft = leg } else { legDraft = leg } } label: {
                            Text("\(store.plan.name(leg.fromID)) → \(store.plan.name(leg.toID)) · \(leg.minutes)분")
                        }
                        Text(leg.sourceLabel + (leg.vehicleClass.map { " · \($0)" } ?? "")).font(.caption).foregroundColor(.secondary)
                        if leg.locationInvalidated == true { Text("하역 위치 변경 · 경로·이동시간 재확인 필요").font(.caption).foregroundColor(.orange) }
                        if let at = leg.capturedAt { Text("읽은 시각: \(at)").font(.caption2).foregroundColor(.secondary) }
                        if let url = leg.pageURL { Button("지도에서 다시 열기") { openRoute(url) }.font(.caption) }
                    }
                    .swipeActions { Button("삭제", role: .destructive) { store.removeLeg(leg.id) } }
                }
            }
        }
    }

    private var results: some View {
        List {
            Section {
                Text(store.message)
                if let result = store.result {
                    ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
                    if let finish = result.finishMinute, let start = result.originDepartureMinute {
                        Text("\(store.plan.planDate) · 출발 \(PlannerClock.text(start)) · 완료 \(PlannerClock.text(finish))").bold()
                        Text("운전 \(result.totalTravelMinutes)분 · 거래처 \(result.rows.count)곳").font(.subheadline)
                        Text(result.loadingValidated ? "이 배치의 적재 조건 통과" : "적재 조건 미검증").font(.caption)
                        Text(result.roadEvidenceValidated == true ? "선택한 도로 조건의 등록 근거 충족" : "도로 조건 전체 미검증").font(.caption)
                        if let fare = result.totalClass1TollWon { Text("회사 복귀 포함 1종 통행료: \(fare)원").font(.subheadline) }
                        else { Text("1종 통행료 합계: 미확인 구간 있음").font(.caption) }
                        if let cargo = result.cargo {
                            NavigationLink("출발·방문별 적재도와 상하차 순서") { CargoResultView(plan: planForCargoResult(result), result: cargo) }
                        }
                        if let summary = result.automaticLoading {
                            Text("자동 배치 \(summary.attemptedLayouts)건 시도 · 경로 포함 통과 \(summary.feasibleLayouts)건 · 파렛트 \(summary.palletCount)장").font(.caption)
                            Button("이 결과를 수동 배치로 저장") { inputs.finishEditing(); store.adoptGeneratedCargo(); section = 4 }
                            Text("저장하면 기존 수동 배치를 이 결과로 바꿉니다. 저장 전까지 기존 배치는 보관됩니다.").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if let rest = result.rest {
                        Text("휴식 \(PlannerClock.text(rest.startMinute))~\(PlannerClock.text(rest.endMinute)) · \(store.plan.name(rest.visitID))").bold()
                    }
                }
            }
            if let result = store.result {
                if let excluded = result.roadExcluded, !excluded.isEmpty {
                    Section("도로 조건으로 제외한 후보") {
                        ForEach(Array(excluded.prefix(12))) { item in
                            Text("\(store.plan.name(item.fromID)) → \(store.plan.name(item.toID)): " + item.reasons.joined(separator: " · ")).font(.caption)
                        }
                    }
                }
                ForEach(result.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(row.position). \(store.plan.name(row.visitID))").font(.headline)
                        Text("도착 \(PlannerClock.text(row.arrivalMinute)) → 출발 \(PlannerClock.text(row.departureMinute))")
                        Text("작업 \(PlannerClock.text(row.serviceStartMinute))~\(PlannerClock.text(row.readyMinute))").font(.caption)
                        if let extra = row.handlingMinutes, extra > 0 { Text("재배치 추가 \(extra)분 포함").font(.caption).foregroundColor(.orange) }
                        Text("\(store.plan.name(row.fromID))에서 \(PlannerClock.text(row.legDepartureMinute)) 출발 · 이동 \(row.travelMinutes)분").font(.caption).foregroundColor(.secondary)
                        if row.waitBeforeLeg > 0 { Text("이전 장소 추가 대기 \(row.waitBeforeLeg)분").font(.caption) }
                        if row.waitBeforeService > 0 { Text("작업 전 대기 \(row.waitBeforeService)분" + (row.restBeforeService ? " · 휴식 60분 포함" : "")).font(.caption) }
                        if row.waitAfterService > 0 { Text("기본 체류 후 추가 대기 \(row.waitAfterService)분").font(.caption) }
                        if row.restMinutesAfterService > 0 { Text("작업 후 휴식 60분").font(.caption) }
                        if let visit = store.plan.visits.first(where: { $0.id == row.visitID }), !visit.orderSummary.isEmpty {
                            Text(visit.orderSummary).font(.caption)
                        }
                        if let snapshot = result.cargo?.snapshots.first(where: { $0.visitID == row.visitID }) {
                            Text("작업 후: " + snapshot.inventory.filter { $0.quantity > 0 }.map { "\(CargoKind.label($0.kind)) \($0.quantity)" }.joined(separator: " · ")).font(.caption)
                        }
                        if let url = store.plan.selectedLeg(row.legID, from: row.fromID, to: row.visitID)?.pageURL {
                            Button("이 구간 지도 열기") { openRoute(url) }.font(.caption)
                        }
                    }.padding(.vertical, 4)
                }
                if store.plan.returnToOrigin, let last = result.rows.last {
                    Section("회사 복귀") {
                        Text("\(store.plan.name(last.visitID)) → \(store.plan.originName) · \(result.returnMinutes)분")
                        if let url = store.plan.selectedLeg(result.returnLegID, from: last.visitID, to: "depot")?.pageURL { Button("복귀 구간 지도 열기") { openRoute(url) } }
                    }
                }
                Text("지도 주소를 다시 열면 네이버가 경로를 재계산할 수 있습니다. 이 결과는 저장한 이동시간에 따른 일정 후보이며 실제 길안내의 경로 고정을 보장하지 않습니다.").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func exportPlan() {
        inputs.finishEditing()
        do {
            exportDocument = CaptureDocument(data: try store.planData())
            exportName = "배송계획_\(store.plan.planDate)"; showExport = true
        } catch { store.errorMessage = error.localizedDescription }
    }
    private func exportInputDiagnostics() {
        guard !preparingInputDiagnostics else { return }
        preparingInputDiagnostics = true
        Task { @MainActor in
            defer { preparingInputDiagnostics = false }
            do {
                let data = try await InputDiagnostics.shared.makeReport()
                exportDocument = CaptureDocument(data: data)
                exportName = "DeliveryRouteProbe_입력진단_\(DeliveryAppInfo.version)"
                showExport = true
            } catch {
                store.errorMessage = "입력 진단 내보내기 실패: \(error.localizedDescription)"
            }
        }
    }
    private func exportResult() {
        inputs.finishEditing()
        do {
            guard let data = store.resultData else { return }
            let object: [String: Any] = ["plan": try JSONSerialization.jsonObject(with: store.planData()), "result": try JSONSerialization.jsonObject(with: data)]
            exportDocument = CaptureDocument(data: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            exportName = "방문순서결과_\(store.plan.planDate)"; showExport = true
        } catch { store.errorMessage = error.localizedDescription }
    }
    private func planForCargoResult(_ result: PlannerResult) -> DeliveryPlan {
        var value = store.plan
        if let cargo = result.generatedCargo { value.cargo = cargo }
        return value
    }
}

struct NumberRow: View {
    let title: String
    @Binding var value: Int
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            IntegerInput(title: title, value: $value)
                .frame(minWidth: 60, maxWidth: 100, minHeight: 44)
        }
    }
}

private struct VisitEditor: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DeliveryVisit
    let otherVisits: [DeliveryVisit]
    let onSave: (DeliveryVisit) -> Void
    init(visit: DeliveryVisit, otherVisits: [DeliveryVisit], onSave: @escaping (DeliveryVisit) -> Void) {
        _draft = State(initialValue: visit); self.otherVisits = otherVisits; self.onSave = onSave
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("거래처") {
                    NativeTextField("이름", text: $draft.name).frame(minHeight: 44)
                    Picker("구분", selection: $draft.kind) {
                        Text("매출처").tag("delivery"); Text("매입처").tag("pickup"); Text("매입·매출처").tag("both")
                    }
                    NumberRow(title: "기본 체류시간(분)", value: $draft.serviceMinutes)
                    NumberRow(title: "허용 추가 대기(분)", value: $draft.maxWaitMinutes)
                    Toggle("일찍 도착해 현장에서 대기 가능", isOn: $draft.allowEarlyArrival)
                    Toggle("이 거래처에서 1시간 휴식 가능", isOn: $draft.canRestHere)
                    Text("기본 체류는 통상 도착부터 출발까지 걸리는 시간입니다. 조기 도착 대기와 휴식은 따로 계산하므로 기본 체류시간에 미리 포함하지 마세요. 추가 대기 한도는 작업 후 휴식을 제외하고 기다릴 수 있는 시간입니다.").font(.caption).foregroundColor(.secondary)
                }
                Section(draft.allowEarlyArrival ? "작업 시작 가능 시각" : "도착·작업 시작 시각") {
                    NativeTextField("가능: 09:00-11:30,13:00-15:00", text: $draft.arrivalWindowsText, keyboard: .numbersAndPunctuation)
                        .frame(minHeight: 44)
                    NativeTextField("회피: 12:00-13:00", text: $draft.avoidWindowsText, keyboard: .numbersAndPunctuation)
                        .frame(minHeight: 44)
                    Text("빈칸은 제한 없음. 9시 이후는 09:00-71:59, 15시까지는 00:00-15:00. 다음 날 1시는 25:00. 회피 시간에는 도착과 작업 시작을 하지 않으며 회피 끝 시각부터 허용합니다.").font(.caption).foregroundColor(.secondary)
                }
                Section("방문 순번") {
                    Stepper(draft.fixedPosition == 0 ? "고정 순번 없음" : "\(draft.fixedPosition)번째 고정", value: $draft.fixedPosition, in: 0...30)
                    Stepper("가장 이른 순번 \(draft.minPosition)", value: $draft.minPosition, in: 1...30)
                    Stepper("가장 늦은 순번 \(draft.maxPosition)", value: $draft.maxPosition, in: 1...30)
                    Picker("바로 앞에 방문할 거래처", selection: $draft.immediatelyAfterID) {
                        Text("지정 없음").tag("")
                        ForEach(otherVisits) { Text($0.name).tag($0.id) }
                    }
                }
                Section("이 거래처보다 먼저 방문할 곳") {
                    if otherVisits.isEmpty { Text("다른 거래처를 등록하면 선택할 수 있습니다.").font(.caption) }
                    ForEach(otherVisits) { visit in
                        Toggle(visit.name, isOn: Binding(get: { draft.afterIDs.contains(visit.id) }, set: { selected in
                            draft.afterIDs.removeAll { $0 == visit.id }
                            if selected { draft.afterIDs.append(visit.id) }
                        }))
                    }
                }
                Section("주문 수량") {
                    ForEach($draft.orders) { $order in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(order.label).font(.subheadline)
                            HStack {
                                NumberRow(title: "배송", value: $order.deliver)
                                Divider()
                                NumberRow(title: "매입", value: $order.pickup)
                            }
                        }
                    }
                    Text("4kg 이하 곡류를 20kg 박스로 포장했다면 박스 수를 입력합니다. 적재 계산을 켰다면 적재 화면의 배송·매입 배치 수량도 주문과 같아야 합니다.").font(.caption).foregroundColor(.secondary)
                }
                Section("메모") { NativeMemoEditor(text: $draft.note).frame(height: 120) }
            }
            .navigationTitle("거래처 조건").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { inputs.finishEditing(); onSave(draft); dismiss() }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}

private struct LegEditor: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DeliveryLeg
    let plan: DeliveryPlan
    let onSave: (DeliveryLeg) -> Void
    init(leg: DeliveryLeg, plan: DeliveryPlan, onSave: @escaping (DeliveryLeg) -> Void) {
        _draft = State(initialValue: leg); self.plan = plan; self.onSave = onSave
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("방향별 이동 구간") {
                    Picker("출발", selection: $draft.fromID) { ForEach(plan.nodes, id: \.id) { Text($0.name).tag($0.id) } }
                    Picker("도착", selection: $draft.toID) { ForEach(plan.nodes, id: \.id) { Text($0.name).tag($0.id) } }
                    NumberRow(title: "이동시간(분)", value: $draft.minutes)
                    Text("이 화면에서 저장하면 직접 입력한 시간으로 등록합니다. 네이버 경로 원문과 차종·요금 정보는 연결하지 않습니다.").font(.caption).foregroundColor(.secondary)
                }
                Section("메모") { NativeTextField("시간의 근거나 주의할 점", text: $draft.note).frame(minHeight: 44) }
                if plan.leg(from: draft.fromID, to: draft.toID) != nil { Text("저장하면 이 후보의 이동시간을 바꿉니다. 다른 후보는 보존됩니다.").font(.caption) }
            }
            .navigationTitle("이동시간 직접 입력").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        inputs.finishEditing()
                        var value = DeliveryLeg(); value.id = draft.id
                        value.fromID = draft.fromID; value.toID = draft.toID
                        value.minutes = draft.minutes; value.note = draft.note
                        onSave(value); dismiss()
                    }.disabled(draft.fromID == draft.toID || draft.toID.isEmpty || draft.minutes < 0 || draft.minutes > 2880)
                }
            }
        }
    }
}

private struct CaptureLegEditor: View {
    @Environment(\.dismiss) private var dismiss
    let capture: RouteCapture
    let data: Data
    let plan: DeliveryPlan
    let onSave: (DeliveryLeg) -> Void
    @State private var fromID = "depot"
    @State private var toID = ""
    @State private var confirmedNames = false
    private var selected: RouteCandidate? {
        let values = capture.candidates.filter(\.selected)
        return values.count == 1 ? values[0] : nil
    }
    private var canSave: Bool {
        guard let minutes = selected?.durationMinutes, minutes.isFinite, minutes >= 0, minutes <= 2880 else { return false }
        return capture.quality.readyForSummaryImport && capture.routePoints.count == 2 && capture.mode == "자동차"
        && fromID != toID && !toID.isEmpty && confirmedNames
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("저장된 네이버 화면") {
                    Text(capture.routePoints.joined(separator: " → "))
                    if let route = selected { Text("\(route.label) · \(route.durationText) · \(route.distanceText)") }
                    Text(capture.vehicleSummary)
                    if let at = capture.capturedAt { Text("읽은 시각: \(at)").font(.caption) }
                    if !capture.quality.readyForSummaryImport || capture.routePoints.count != 2 {
                        Text("경유지 없는 두 장소의 자동차 경로를 검색한 뒤 화면 읽기를 다시 해 주세요.").foregroundColor(.red)
                    }
                }
                Section("계획의 거래처와 연결") {
                    Picker("출발 거래처", selection: $fromID) { ForEach(plan.nodes, id: \.id) { Text($0.name).tag($0.id) } }
                    Picker("도착 거래처", selection: $toID) {
                        Text("선택해 주세요").tag("")
                        ForEach(plan.nodes, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Toggle("위 네이버 출발·도착지가 선택한 두 거래처와 각각 일치함을 확인했습니다", isOn: $confirmedNames)
                    Text("건물 이름이 같아도 입구가 다를 수 있습니다. 실제 하역 위치와 차로 방향 확인은 별도입니다.").font(.caption).foregroundColor(.secondary)
                    if plan.leg(from: fromID, to: toID) != nil { Text("같은 방향의 별도 경로 후보로 추가합니다.").font(.caption) }
                }
                Text("분 미만은 올림하여 저장합니다. 차종별 통행료와 도착 방향 문구는 원문과 함께 보관하지만, 이번 순서 계산에는 이동시간만 사용합니다.").font(.caption)
            }
            .navigationTitle("네이버 경로 연결").navigationBarTitleDisplayMode(.inline)
            .onChange(of: fromID) { _ in confirmedNames = false }
            .onChange(of: toID) { _ in confirmedNames = false }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("연결 저장") {
                        guard canSave, let route = selected, let minutes = route.durationMinutes else { return }
                        var leg = DeliveryLeg()
                        leg.fromID = fromID; leg.toID = toID; leg.minutes = Int(minutes.rounded(.up)); leg.source = "naver"
                        leg.capturedAt = capture.capturedAt; leg.vehicleClass = capture.vehicleClass
                        leg.distanceMeters = route.distanceMeters; leg.tollWon = route.tollWon; leg.routeLabel = route.label
                        leg.arrivalSideText = capture.detail.arrivalSideText
                        leg.pageURL = capture.pageURL; leg.captureJSON = String(data: data, encoding: .utf8)
                        onSave(leg); dismiss()
                    }.disabled(!canSave)
                }
            }
        }
    }
}
