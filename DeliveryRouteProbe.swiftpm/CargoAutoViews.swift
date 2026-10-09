import SwiftUI

struct CargoAutoSettingsSections: View {
    @Binding var settings: CargoAutoSettings
    let visits: [DeliveryVisit]
    @State private var transferDraft: CargoTransfer?
    private func name(_ id: String) -> String { visits.first { $0.id == id }?.name ?? "미지정" }

    var body: some View {
        Group {
            Section("자동 배치 조건") {
                Picker("파렛트 수", selection: $settings.palletMode) {
                    Text("1장·2장 모두 비교").tag("compare")
                    Text("1장으로 제한").tag("one")
                    Text("2장으로 제한").tag("two")
                }
                Picker("파렛트를 붙일 벽", selection: $settings.palletSide) {
                    Text("왼쪽 벽").tag("left"); Text("오른쪽 벽").tag("right")
                }
                Text("파렛트는 앞쪽부터 앞뒤로 놓습니다. 수량이 줄어도 빈 파렛트를 중간에 없애지 않습니다. 한 파렛트에는 한 규격의 포대 패턴을 사용합니다.").font(.caption)
                Picker("작업문", selection: $settings.accessSide) {
                    Text("후문").tag("rear"); Text("왼쪽 측문").tag("left"); Text("오른쪽 측문").tag("right")
                }
                AutoNumberRow(title: "문 개구부 시작 위치(mm)", value: $settings.doorStartMM)
                AutoNumberRow(title: "문이 실제로 열린 폭(mm)", value: $settings.doorWidthMM)
                Text("후문은 왼쪽 끝에서, 측문은 앞쪽 끝에서 잽니다. 화물을 쌓인 높이 그대로 문까지 수평 이동할 수 있는지 계산합니다. 휘어서 지나가거나 더 높이 들어 올려 넘기는 작업은 가정하지 않습니다. 열린 작업문은 계란 지지벽으로 세지 않습니다.").font(.caption).foregroundColor(.secondary)
                AutoNumberRow(title: "박스 최대 층수", value: $settings.boxMaxLayers)
                AutoNumberRow(title: "4kg 낱포대 최대 층수", value: $settings.rice4MaxLayers)
                Text("박스·4kg 낱포대를 취급하는 경우에만 해당 한도를 입력합니다. 20kg 10층·10kg 13층·25~40kg 5층은 이미 적용되어 있습니다. 계란은 배치의 사방 지지 높이로 계산합니다.").font(.caption)
            }
            Section("매입품을 다른 거래처로 바로 배송") {
                ForEach(settings.transfers) { transfer in
                    Button { transferDraft = transfer } label: {
                        VStack(alignment: .leading) {
                            Text("\(name(transfer.fromID)) → \(name(transfer.toID))")
                            Text("\(CargoKind.label(transfer.kind)) \(transfer.quantity)개").font(.caption)
                        }
                    }.swipeActions { Button("삭제", role: .destructive) { settings.transfers.removeAll { $0.id == transfer.id } } }
                }
                Button("매입→배송 연결 추가") { transferDraft = CargoTransfer() }
                    .disabled(visits.count < 2 || settings.transfers.count >= 100)
                Text("연결하지 않은 배송분은 회사에서 싣고 출발하며, 연결하지 않은 매입품은 회사로 가져옵니다. 연결 수량은 거래처의 배송·매입 주문에 각각 포함되어 있어야 합니다. 기존 수동 배치의 연결은 자동으로 가져오지 않습니다.").font(.caption).foregroundColor(.secondary)
            }
            Section {
                Text("상단 순서 계산을 누르면 배치와 방문 순서를 함께 비교합니다. 결과의 적재도에서 회사 출발분과 매입할 자리, 위치별 쌓임 순서를 확인할 수 있습니다.").font(.caption)
            }
        }
        .sheet(item: $transferDraft) { draft in
            CargoTransferEditor(draft: draft, visits: visits) { value in
                if let index = settings.transfers.firstIndex(where: { $0.id == value.id }) { settings.transfers[index] = value }
                else { settings.transfers.append(value) }
            }
        }
    }
}

private struct AutoNumberRow: View {
    let title: String
    @Binding var value: Int
    var body: some View {
        HStack { Text(title); Spacer(); IntegerInput(title: title, value: $value).frame(width: 90, height: 44) }
    }
}

struct CargoCoordinateRow: View {
    let title: String
    @Binding var value: Double
    @State private var draft = ""
    @State private var isEditing = false
    private func formatted(_ number: Double) -> String {
        String(format: "%.3f", number).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
    var body: some View {
        HStack {
            Text(title); Spacer()
            NativeTextField(title, text: Binding(get: { draft }, set: { text in
                draft = text
                if text.isEmpty { value = 0 }
                else if let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite, (0...20000).contains(number) { value = number }
            }), keyboard: .decimalPad, alignment: .right, onEditingChanged: { editing in
                isEditing = editing
                if !editing { draft = formatted(value) }
            }).frame(width: 105, height: 44)
            Text("mm").font(.caption)
        }
        .onAppear { draft = formatted(value) }
        .onChange(of: value) { _, number in if !isEditing { draft = formatted(number) } }
    }
}

private struct CargoTransferEditor: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State var draft: CargoTransfer
    let visits: [DeliveryVisit]
    let onSave: (CargoTransfer) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Picker("매입하는 거래처", selection: $draft.fromID) {
                    Text("선택").tag(""); ForEach(visits) { Text($0.name).tag($0.id) }
                }
                Picker("배송할 거래처", selection: $draft.toID) {
                    Text("선택").tag(""); ForEach(visits) { Text($0.name).tag($0.id) }
                }
                Picker("품목", selection: $draft.kind) { ForEach(CargoKind.all, id: \.self) { Text(CargoKind.label($0)).tag($0) } }
                AutoNumberRow(title: "연결 수량", value: $draft.quantity)
                Text("이 수량은 회사 출발분에서 제외하고 매입처 방문 때 싣습니다. 매입처를 배송처보다 먼저 방문해야 합니다.").font(.caption)
            }
            .navigationTitle("매입→배송 연결").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { inputs.finishEditing(); onSave(draft); dismiss() }
                        .disabled(draft.fromID.isEmpty || draft.toID.isEmpty || draft.fromID == draft.toID || draft.quantity < 1)
                }
            }
        }
    }
}
