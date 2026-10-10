import SwiftUI

struct SimpleDeliveryTimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inputs: NativeInputSession
    let save: (DeliveryVisit) -> Void
    @State private var draft: DeliveryVisit
    @State private var error: String?
    init(visit: DeliveryVisit, save: @escaping (DeliveryVisit) -> Void) {
        self.save = save; _draft = State(initialValue: visit)
    }
    var body: some View {
        NavigationStack {
            Form {
                Text(draft.name).bold()
                NumberRow(title: "배송 작업시간(분)", value: $draft.serviceMinutes)
                NativeTextField("배송 가능 시간 · 예: 09:00-11:30", text: $draft.arrivalWindowsText, keyboard: .numbersAndPunctuation).frame(minHeight: 44)
                Text("시간 제한이 없으면 비워 두세요. 하나의 시간 구간을 입력하며 티맵에는 희망 도착 시간으로 전달합니다.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.navigationTitle("배송 시간 조건").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("저장") {
                        inputs.finishEditing()
                        do {
                            var candidate = draft
                            candidate.avoidWindowsText = ""
                            var plan = DeliveryPlan(); plan.visits = [candidate]
                            let timing = try TMapBridge.timeInputs(plan)
                            guard timing.stops.allSatisfy({ $0.windowCount <= 1 }) else { throw PlannerFailure.message("배송 가능 시간은 하나의 구간으로 입력해 주세요.") }
                            save(candidate); dismiss()
                        } catch { self.error = error.localizedDescription }
                    } }
                }
        }
    }
}
