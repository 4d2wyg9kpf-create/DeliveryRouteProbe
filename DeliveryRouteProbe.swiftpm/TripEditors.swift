import SwiftUI

struct TripWorkEditor: View {
    let plan: DeliveryPlan
    let report: TripReport
    let onSave: (TripEvent) -> Void
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var operation = "unload"
    @State private var lotID = ""
    @State private var sourceID = ""
    @State private var targetID = ""
    @State private var quantity = 1
    @State private var duration = 3
    @State private var minute: Int

    init(plan: DeliveryPlan, report: TripReport, initialMinute: Int, onSave: @escaping (TripEvent) -> Void) {
        self.plan = plan; self.report = report; self.onSave = onSave
        _minute = State(initialValue: initialMinute)
        _operation = State(initialValue: report.phase == "ready" ? "relocate" : "unload")
    }
    private var lots: [CargoLot] {
        report.cargoConfig.lots.filter { lot in
            if operation == "load" { return report.phase == "atStop" && lot.loadAt == report.currentID }
            let present = report.positions.contains { $0.lotID == lot.id }
            return present && (operation == "relocate" || report.phase == "returned" || lot.unloadAt == report.currentID)
        }
    }
    private var lot: CargoLot? { lots.first { $0.id == lotID } }
    private var sourceColumns: [CargoColumn] {
        report.cargoConfig.columns.filter { column in report.positions.contains { $0.lotID == lotID && $0.columnID == column.id } }
    }
    private var targetColumns: [CargoColumn] {
        guard let lot = lot else { return [] }
        return report.cargoConfig.columns.filter { column in
            column.kind == lot.kind || (lot.kind == "grainBox20" && ["rice20", "rice10", "rice4", "bag25to40"].contains(column.kind))
        }
    }
    private var valid: Bool {
        lot != nil && (1...20000).contains(quantity) && (0...1440).contains(duration) && minute >= report.clock && minute + min(1440, max(0, duration)) <= 4319 &&
        (operation == "load" || !sourceID.isEmpty) && (operation == "unload" || !targetID.isEmpty) && (operation != "relocate" || sourceID != targetID)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("실제 작업") {
                    Picker("작업", selection: $operation) {
                        if report.phase != "ready" { Text("하차").tag("unload") }
                        if report.phase == "atStop" { Text("상차").tag("load") }
                        Text("다른 자리로 옮기기").tag("relocate")
                    }
                    Picker("화물 묶음", selection: $lotID) {
                        Text("선택해 주세요").tag("")
                        ForEach(lots) { lot in Text("\(CargoKind.label(lot.kind)) → \(plan.name(lot.unloadAt)) · \(columnName(lot.columnID))").tag(lot.id) }
                    }
                    if operation != "load" {
                        Picker("현재 자리", selection: $sourceID) {
                            Text("선택해 주세요").tag("")
                            ForEach(sourceColumns) { column in
                                let amount = report.positions.filter { $0.lotID == lotID && $0.columnID == column.id }.reduce(0) { $0 + $1.quantity }
                                Text("\(column.name) · \(amount)개").tag(column.id)
                            }
                        }
                    }
                    if operation != "unload" {
                        Picker("놓을 자리", selection: $targetID) {
                            Text("선택해 주세요").tag("")
                            ForEach(targetColumns) { Text($0.name + ($0.temporaryFloor == true ? " · 정차 중 임시" : "")).tag($0.id) }
                        }
                    }
                    HStack { Text("실제 수량"); IntegerInput(title: "수량", value: $quantity) }
                    Text("더미 위에서 한 개씩 옮기며 통로·지지·높이를 검사합니다. 재배치는 재고 총량을 바꾸지 않습니다. 쌀 임시 바닥 자리는 출발 전에 비워야 합니다.").font(.caption)
                }
                Section("작업 시간") {
                    TripMinutePicker(title: "실제 시작", minute: $minute)
                    HStack { Text("실제로 걸린 시간(분)"); IntegerInput(title: "작업 시간", value: $duration) }
                    Text("종료 \(PlannerClock.text(min(4319, minute + min(1440, max(0, duration)))))")
                }
            }
            .navigationTitle("실제 상하차·재배치").navigationBarTitleDisplayMode(.inline)
            .onAppear { resetLot() }
            .onChange(of: operation) { _, _ in resetLot() }
            .onChange(of: lotID) { _, _ in resetColumns() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("실제 작업 기록") { save() }.disabled(!valid) }
            }
        }
    }
    private func columnName(_ id: String) -> String { report.cargoConfig.columns.first { $0.id == id }?.name ?? id }
    private func resetLot() { lotID = lots.first?.id ?? ""; resetColumns() }
    private func resetColumns() {
        sourceID = sourceColumns.first?.id ?? ""
        targetID = operation == "load" ? (lot?.columnID ?? "") : (targetColumns.first { $0.id != sourceID }?.id ?? "")
    }
    private func save() {
        guard valid, let lot = lot else { return }
        inputs.finishEditing()
        var action = CargoAction(lotID: lot.id, columnID: operation == "unload" ? sourceID : targetID, kind: lot.kind, operation: operation, quantity: quantity)
        if operation == "relocate" { action.fromColumnID = sourceID; action.toColumnID = targetID }
        var event = TripEvent(type: "work", minute: minute); event.endMinute = minute + duration; event.actions = [action]
        onSave(event); dismiss()
    }
}

struct TripTargetEditor: View {
    let plan: DeliveryPlan
    let report: TripReport
    let minute: Int
    let onSave: (TripEvent) -> Void
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var lineID = ""
    @State private var quantity = 0
    @State private var note = ""
    private var remaining: [TripVariance] { report.variance.filter { !$0.complete } }
    private var selected: TripVariance? { remaining.first { $0.id == lineID } }
    var body: some View {
        NavigationStack {
            Form {
                Picker("변경할 주문", selection: $lineID) {
                    Text("선택해 주세요").tag("")
                    ForEach(remaining) { line in
                        Text("\(plan.name(line.visitID)) · \(CargoKind.label(line.kind)) \(line.operation == "load" ? "매입" : "배송") · \(columnName(line.lotID))").tag(line.id)
                    }
                }
                if let line = selected { Text("이 묶음의 현재 주문 \(line.planned)개 · 실제 작업 \(line.actual)개").font(.caption) }
                HStack { Text("변경 후 이 묶음의 전체 수량"); IntegerInput(title: "수량", value: $quantity) }
                NativeTextField("변경 사유", text: $note).frame(minHeight: 44)
                Text("주문 변경은 차량 재고를 바꾸지 않습니다. 이미 완료한 거래처 기록과 원래 주문은 보존합니다. 매입 수량과 이후 배송 수량은 각각 변경합니다.").font(.caption)
            }
            .navigationTitle("남은 주문 수량 변경").navigationBarTitleDisplayMode(.inline)
            .onAppear { lineID = remaining.first?.id ?? ""; quantity = selected?.planned ?? 0 }
            .onChange(of: lineID) { _, _ in quantity = selected?.planned ?? 0 }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("변경 기록") {
                        guard let line = selected else { return }; inputs.finishEditing()
                        var event = TripEvent(type: "target", minute: minute); event.lotID = line.lotID; event.operation = line.operation; event.quantity = quantity; event.note = note
                        onSave(event); dismiss()
                    }.disabled(selected == nil || !(0...20000).contains(quantity) || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    private func columnName(_ lotID: String) -> String {
        let columnID = report.cargoConfig.lots.first { $0.id == lotID }?.columnID ?? ""
        return report.cargoConfig.columns.first { $0.id == columnID }?.name ?? columnID
    }
}
