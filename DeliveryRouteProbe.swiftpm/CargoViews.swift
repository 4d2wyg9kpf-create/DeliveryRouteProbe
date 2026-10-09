import SwiftUI

struct CargoSettingsView: View {
    @Binding var config: CargoPlan
    let visits: [DeliveryVisit]
    @State private var palletDraft: CargoPallet?
    @State private var columnDraft: CargoColumn?
    @State private var lotDraft: CargoLot?
    private var automatic: Bool { config.autoLayout?.enabled == true }
    private var autoSettings: Binding<CargoAutoSettings> {
        Binding(get: { config.autoLayout ?? CargoAutoSettings() }, set: { config.autoLayout = $0 })
    }

    private func placeName(_ id: String) -> String {
        id == "depot" ? DeliveryPlan.companyName : visits.first { $0.id == id }?.name ?? "삭제된 거래처"
    }

    var body: some View {
        Form {
            Section {
                Toggle("적재 조건을 방문 순서에 반영", isOn: $config.enabled)
                Picker("배치 방식", selection: Binding(get: { automatic }, set: { enabled in
                    var settings = config.autoLayout ?? CargoAutoSettings(); settings.enabled = enabled; config.autoLayout = settings
                })) {
                    Text("주문에서 자동 생성").tag(true)
                    Text("직접 등록한 배치").tag(false)
                }
                Text(automatic ? "거래처 주문과 아래 차량 조건으로 배치와 방문 순서를 함께 비교합니다. 기존 수동 배치는 보관하며, 선택한 결과를 수동 배치로 저장할 수 있습니다." : "등록한 배치를 출발점으로 배송·매입 순서를 계산합니다. 재배치를 켜면 빈자리로 옮기는 작업도 비교합니다. 치수는 mm, 좌표는 화물칸 앞쪽 왼쪽을 0으로 입력합니다.").font(.caption)
            }
            Section("운행 중 재배치") {
                Toggle("빈자리로 옮기는 작업도 계산", isOn: Binding(get: { config.rehandling?.enabled == true }, set: { value in
                    var settings = config.rehandling ?? CargoRehandlingSettings(); settings.enabled = value; config.rehandling = settings
                }))
                if config.rehandling?.enabled == true {
                    HStack { Text("한 거래처 최대 이동 개수 · 1~40"); IntegerInput(title: "이동 한도", value: Binding(get: { config.rehandling?.maxMovedUnits ?? 12 }, set: { config.rehandling?.maxMovedUnits = $0 })) }
                    HStack { Text("한 개를 옮기는 시간(초)"); IntegerInput(title: "이동 시간", value: Binding(get: { config.rehandling?.secondsPerUnit ?? 60 }, set: { config.rehandling?.secondsPerUnit = $0 })) }
                    HStack { Text("재배치 준비시간(분)"); IntegerInput(title: "준비 시간", value: Binding(get: { config.rehandling?.setupMinutes ?? 0 }, set: { config.rehandling?.setupMinutes = $0 })) }
                    Text("다른 자리로 옮긴 뒤 다시 가져오면 2회로 셉니다. 등록한 자리·통로·각 단계의 지지를 검사하며 추가 작업시간을 더합니다. 바닥에 임시로 둔 쌀은 출발 전에 파렛트로 돌려놓습니다.").font(.caption)
                }
            }
            Section("화물칸·파렛트 실측") {
                CargoNumberRow(title: "화물칸 안쪽 폭", value: $config.truckWidthMM)
                CargoNumberRow(title: "화물칸 안쪽 길이", value: $config.truckLengthMM)
                CargoNumberRow(title: "화물칸 안쪽 높이", value: $config.truckHeightMM)
                CargoNumberRow(title: "정사각 파렛트 한 변", value: $config.palletSideMM)
                CargoNumberRow(title: "파렛트 높이", value: $config.palletHeightMM)
                Text("0은 미입력입니다. 측면·후면 여유는 실제 화물칸과 파렛트 위치로 계산합니다. 차량 외형 높이와 도로 높이 제한은 별도입니다.").font(.caption).foregroundColor(.secondary)
            }
            Section("포장 실측") {
                DisclosureGroup("쌀포대") {
                    CargoNumberRow(title: "20kg 한 포대 높이", value: $config.rice20HeightMM)
                    CargoNumberRow(title: "10kg 포대 폭", value: $config.rice10WidthMM)
                    CargoNumberRow(title: "10kg 한 포대 높이", value: $config.rice10HeightMM)
                    CargoNumberRow(title: "4kg 한 포대 높이", value: $config.rice4HeightMM)
                    Text("평면 크기는 알려주신 파렛트 비율을 사용합니다. 10kg 길이는 파렛트 한 변−폭×2입니다. 한 층은 20kg 5자리·최대 10층, 10kg 8자리·최대 13층, 4kg 15자리입니다.").font(.caption)
                }
                DisclosureGroup("25~40kg 포대 · 한 층 6포, 최대 5층") {
                    CargoNumberRow(title: "포대 폭", value: $config.bulkBagWidthMM)
                    CargoNumberRow(title: "포대 길이", value: $config.bulkBagDepthMM)
                    CargoNumberRow(title: "한 포대 적층 높이", value: $config.bulkBagHeightMM)
                    Text("파렛트 한 장에 3×2로 놓습니다. 최대 30포이며 실제 치수와 허용 높이도 함께 적용합니다.").font(.caption)
                }
                DisclosureGroup("계란·곡류 박스") {
                    CargoNumberRow(title: "계란판 한 변", value: $config.eggSideMM)
                    CargoNumberRow(title: "계란 한 판 적층 높이", value: $config.eggTrayHeightMM)
                    CargoNumberRow(title: "20kg 곡류 박스 폭", value: $config.boxWidthMM)
                    CargoNumberRow(title: "20kg 곡류 박스 길이", value: $config.boxDepthMM)
                    CargoNumberRow(title: "20kg 곡류 박스 높이", value: $config.boxHeightMM)
                }
                Text("한 개를 추가했을 때 늘어나는 실제 적층 높이를 입력합니다. 사용하지 않는 품목은 비워둘 수 있습니다.").font(.caption).foregroundColor(.secondary)
            }
            if automatic {
                CargoAutoSettingsSections(settings: autoSettings, visits: visits)
            } else {
            if let door = config.accessGeometry {
                Section("자동 생성에서 이어받은 작업문") {
                    Text("\(CargoKind.directionName(door.side)) · 시작 \(door.startMM)mm · 폭 \(door.widthMM)mm")
                    Text("자동 통로가 지정된 위치는 현재 좌표로 통로를 다시 계산합니다. 문을 바꾸려면 자동 배치에서 작업문을 변경해 다시 계산해 주세요.").font(.caption)
                }
            }
            Section("파렛트 · 최대 2장") {
                ForEach(config.pallets) { pallet in
                    Button { palletDraft = pallet } label: {
                        Text("\(pallet.name) · 왼쪽 \(pallet.xMM), 앞쪽 \(pallet.yMM)mm")
                    }.swipeActions { Button("삭제", role: .destructive) { config.pallets.removeAll { $0.id == pallet.id } } }
                }
                Button("파렛트 추가") {
                    var p = CargoPallet(); p.name = "파렛트 \(config.pallets.count + 1)"; palletDraft = p
                }.disabled(config.pallets.count >= 2)
            }
            Section("적재 위치 · 한 위치는 세로로 쌓는 한 더미") {
                if config.truckWidthMM > 0, config.truckLengthMM > 0 {
                    CargoFloorMap(config: config, snapshot: nil).frame(height: 320)
                }
                ForEach(config.columns) { column in
                    Button { columnDraft = column } label: {
                        VStack(alignment: .leading) {
                            Text(column.name)
                            Text("\(CargoKind.label(column.kind)) · 받침 위 \(column.maxHeightMM)mm까지").font(.caption)
                        }
                    }.swipeActions { Button("삭제", role: .destructive) { config.columns.removeAll { $0.id == column.id } } }
                }
                Button("적재 위치 추가") {
                    var c = CargoColumn(); c.palletID = config.pallets.first?.id ?? ""
                    c.name = "위치 \(config.columns.count + 1)"; columnDraft = c
                }.disabled(config.columns.count >= 160)
                Text("한 파렛트에는 한 규격의 포대 자리를 등록합니다. 곡류 박스는 빈 바닥·빈 파렛트 면적·쌀포대 위·바닥의 박스 위에 배치합니다. 위치를 삭제한 뒤 남은 배치·지지 연결은 다시 지정해야 합니다.").font(.caption).foregroundColor(.secondary)
            }
            Section("배송·매입 화물 배치") {
                ForEach(config.lots) { lot in
                    Button { lotDraft = lot } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(CargoKind.label(lot.kind)) \(lot.quantity)개 · \(config.columns.first { $0.id == lot.columnID }?.name ?? "위치 미지정")")
                            Text("\(placeName(lot.loadAt)) → \(placeName(lot.unloadAt)) · 쌓임 \(lot.stackOrder)").font(.caption)
                        }
                    }.swipeActions { Button("삭제", role: .destructive) { config.lots.removeAll { $0.id == lot.id } } }
                }
                Button("화물 배치 추가") {
                    var l = CargoLot(); l.columnID = config.columns.first?.id ?? ""
                    l.kind = config.columns.first?.kind ?? "rice20"; l.unloadAt = visits.first?.id ?? ""
                    l.stackOrder = min(99999, max(0, config.lots.map(\.stackOrder).max() ?? 0)) + 1; lotDraft = l
                }.disabled(config.columns.isEmpty || visits.isEmpty || config.lots.count >= 600)
                Text("주문을 위치별로 나누어 배치합니다. 회사 출발분은 같은 위치에서 쌓임 번호가 작은 묶음부터 아래에 놓습니다. 거래처 매입분은 그곳에서 기존 화물 위에 쌓습니다. 매입품을 이후 거래처에 배송하는 연결도 가능합니다.").font(.caption).foregroundColor(.secondary)
            }
            }
            Section("검사하는 조건") {
                Text("겹침·높이·파렛트별 자리 수, 위에 덮인 배송분, 등록한 통로의 막힘, 계란의 접촉·사방 지지를 검사합니다. 거래처에서는 한 개씩 내리거나 실은 중간 상태까지 검사합니다.")
                Text("자동 생성은 선택한 작업문 개구부까지 화물을 같은 높이에서 수평으로 옮길 수 있는지 계산합니다. 제한된 격자 패턴을 비교하며 더 높이 들어 올려 넘기기·차량 밖 임시 하차·총중량·실차 전도 안정성 검증은 포함하지 않습니다. 재배치는 등록한 화물칸 내부 자리 사이에서 계산합니다.")
            }.font(.caption)
        }
        .sheet(item: $palletDraft) { draft in
            CargoPalletEditor(draft: draft) { value in
                if let i = config.pallets.firstIndex(where: { $0.id == value.id }) { config.pallets[i] = value }
                else { config.pallets.append(value) }
            }
        }
        .sheet(item: $columnDraft) { draft in
            CargoColumnEditor(draft: draft, config: config) { value in
                var edited = value; edited.accessSource = nil
                if let i = config.columns.firstIndex(where: { $0.id == value.id }) { config.columns[i] = edited }
                else { config.columns.append(edited) }
            }
        }
        .sheet(item: $lotDraft) { draft in
            CargoLotEditor(draft: draft, config: config, visits: visits) { value in
                if let i = config.lots.firstIndex(where: { $0.id == value.id }) { config.lots[i] = value }
                else { config.lots.append(value) }
            }
        }
    }
}

private struct CargoNumberRow: View {
    let title: String
    @Binding var value: Int
    var body: some View {
        HStack {
            Text(title); Spacer()
            IntegerInput(title: title, value: $value).frame(width: 95, height: 44)
            Text("mm").font(.caption).foregroundColor(.secondary)
        }
    }
}

private struct CargoPalletEditor: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State var draft: CargoPallet
    let onSave: (CargoPallet) -> Void
    var body: some View {
        NavigationStack {
            Form {
                NativeTextField("파렛트 이름", text: $draft.name).frame(minHeight: 44)
                CargoNumberRow(title: "왼쪽 벽에서의 거리", value: $draft.xMM)
                CargoNumberRow(title: "앞쪽 벽에서의 거리", value: $draft.yMM)
                Text("파렛트의 왼쪽 앞 모서리 위치입니다. 운행 중 빈 파렛트도 이 위치에 남습니다.").font(.caption)
            }
            .navigationTitle("파렛트 위치").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { inputs.finishEditing(); onSave(draft); dismiss() } }
            }
        }
    }
}

struct CargoColumnEditor: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State var draft: CargoColumn
    let config: CargoPlan
    let onSave: (CargoColumn) -> Void
    private var others: [CargoColumn] { config.columns.filter { $0.id != draft.id } }
    var body: some View {
        NavigationStack {
            Form {
                Section("한 더미의 위치와 규격") {
                    NativeTextField("위치 이름", text: $draft.name).frame(minHeight: 44)
                    Picker("기본 품목", selection: $draft.kind) {
                        ForEach(CargoKind.all, id: \.self) { Text(CargoKind.label($0)).tag($0) }
                    }
                    Picker("받침", selection: $draft.palletID) {
                        Text("화물칸 바닥").tag("")
                        ForEach(config.pallets) { Text($0.name).tag($0.id) }
                    }
                    Toggle("정차 중 쌀을 잠시 둘 바닥 자리", isOn: Binding(get: { draft.temporaryFloor == true }, set: { draft.temporaryFloor = $0 }))
                    Toggle("기존 자리와 겹칠 수 있는 대체 위치", isOn: Binding(get: { draft.alternativePosition == true }, set: { draft.alternativePosition = $0 }))
                    Text("대체 위치는 실제 화물이 겹치지 않을 때만 사용합니다. 쌀 임시 바닥 자리는 파렛트 밖 빈 공간이며 출발 전 비워야 합니다.").font(.caption)
                    Toggle("평면을 90도 돌려 놓음", isOn: $draft.rotated)
                    CargoCoordinateRow(title: "왼쪽 벽에서의 거리", value: $draft.xMM)
                    CargoCoordinateRow(title: "앞쪽 벽에서의 거리", value: $draft.yMM)
                    CargoNumberRow(title: "받침 위 허용 적재 높이", value: $draft.maxHeightMM)
                    let size = config.size(of: draft)
                    Text("바닥 크기 \(String(format: "%.0f", max(0, size.width))) × \(String(format: "%.0f", max(0, size.depth)))mm. 한 위치에 수량 3을 배치하면 세로로 3개 쌓습니다.").font(.caption)
                }
                Section("하역 통로를 막는 위치") {
                    ForEach(others) { column in
                        Toggle(column.name, isOn: Binding(get: { draft.blockedByIDs.contains(column.id) }, set: { selected in
                            draft.blockedByIDs.removeAll { $0 == column.id }
                            if selected { draft.blockedByIDs.append(column.id) }
                        }))
                    }
                    Toggle("실제 작업 출입문·통로를 확인함", isOn: $draft.accessConfirmed)
                    if draft.accessSource == "geometry" { Text("자동으로 계산한 직선 통로입니다. 이 위치를 수동으로 수정해 저장할 때는 실제 통로를 확인해 주세요.").font(.caption) }
                    Text("선택한 위치에 화물이 남아 있으면 이 더미에 접근할 수 없는 것으로 계산합니다. 막는 위치가 없어도 사용할 문과 통로를 확인해 주세요. 위아래 덮임은 자동 검사합니다.").font(.caption).foregroundColor(.secondary)
                }
                if draft.kind == "eggTray" {
                    Section("계란의 네 방향 지지") {
                        ForEach($draft.supports) { $support in
                            VStack(alignment: .leading) {
                                Picker(CargoKind.directionName(support.direction), selection: $support.targetID) {
                                    Text("지지 없음").tag("")
                                    Text("이 방향의 벽").tag("wall:" + support.direction)
                                    ForEach(config.pallets) { Text($0.name).tag("pallet:" + $0.id) }
                                    ForEach(others) { Text($0.name).tag("column:" + $0.id) }
                                }
                                Picker("간격", selection: $support.mode) {
                                    Text("직접 접촉").tag("contact")
                                    Text("두 판 미만의 좁은 공간").tag("narrow")
                                }
                            }
                        }
                        Text("사방을 막지 못하면 최대 5판이며 한 방향 이상 접촉해야 합니다. 사방 지지가 있으면 가장 낮은 지지물보다 5판 높은 곳까지 쌓습니다. 정확히 5판 차이도 허용합니다. 좁은 공간은 남은 간격이 한 판 폭보다 작고 해당 지지면이 이어져 있을 때 적용합니다.").font(.caption)
                    }
                }
            }
            .navigationTitle("적재 위치").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { inputs.finishEditing(); onSave(draft); dismiss() }.disabled(draft.name.isEmpty) }
            }
        }
    }
}

private struct CargoLotEditor: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State var draft: CargoLot
    let config: CargoPlan
    let visits: [DeliveryVisit]
    let onSave: (CargoLot) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Picker("적재 위치", selection: $draft.columnID) {
                    Text("선택해 주세요").tag("")
                    ForEach(config.columns) { Text($0.name).tag($0.id) }
                }
                Picker("품목", selection: $draft.kind) {
                    ForEach(CargoKind.all, id: \.self) { Text(CargoKind.label($0)).tag($0) }
                }
                HStack { Text("이 위치에 쌓는 수량"); IntegerInput(title: "수량", value: $draft.quantity) }
                Picker("싣는 장소", selection: $draft.loadAt) {
                    Text(DeliveryPlan.companyName).tag("depot")
                    ForEach(visits) { Text($0.name).tag($0.id) }
                }
                Picker("내리는 장소", selection: $draft.unloadAt) {
                    Text("선택해 주세요").tag("")
                    Text(DeliveryPlan.companyName).tag("depot")
                    ForEach(visits) { Text($0.name).tag($0.id) }
                }
                HStack { Text("같은 장소에서 싣는 쌓임 번호"); IntegerInput(title: "쌓임 번호", value: $draft.stackOrder) }
                Text("같은 위치에 같은 장소에서 싣는 묶음끼리는 작은 번호가 아래입니다. 매입처에서 실을 화물은 그 시점에 남은 화물 위에 놓습니다. 내리는 곳이 회사인 매입품은 복귀할 때까지 남습니다.").font(.caption)
                Text("이 화면은 화물 위치를 지정합니다. 거래처 주문 수량은 거래처 화면에서 별도로 입력하며, 두 수량이 맞지 않으면 계산을 중지합니다.").font(.caption).foregroundColor(.secondary)
            }
            .navigationTitle("화물 배치").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { inputs.finishEditing(); onSave(draft); dismiss() }
                        .disabled(draft.columnID.isEmpty || draft.unloadAt.isEmpty || draft.loadAt == draft.unloadAt || draft.quantity < 1 || draft.stackOrder < 1)
                }
            }
        }
    }
}

struct CargoFloorMap: View {
    let config: CargoPlan
    let snapshot: CargoSnapshot?
    private func color(_ kind: String) -> Color {
        kind == "eggTray" ? .orange : kind == "grainBox20" ? .purple : .brown
    }
    var body: some View {
        VStack(spacing: 4) {
            Text("차량 앞쪽").font(.caption)
            GeometryReader { geometry in
                let width = CGFloat(max(1, config.truckWidthMM))
                let length = CGFloat(max(1, config.truckLengthMM))
                let scale = min(geometry.size.width / width, geometry.size.height / length)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.secondary.opacity(0.06))
                    ForEach(config.pallets) { pallet in
                        Rectangle().stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .frame(width: CGFloat(config.palletSideMM) * scale, height: CGFloat(config.palletSideMM) * scale)
                            .offset(x: CGFloat(pallet.xMM) * scale, y: CGFloat(pallet.yMM) * scale)
                    }
                    ForEach(config.columns.filter { column in snapshot == nil || column.alternativePosition != true || (snapshot?.columns.first { $0.id == column.id }?.quantity ?? 0) > 0 }) { column in
                        let size = config.size(of: column)
                        let state = snapshot?.columns.first { $0.id == column.id }
                        let empty = state?.quantity == 0
                        ZStack {
                            Rectangle().fill(color(column.kind).opacity(empty ? 0.07 : 0.30))
                            Rectangle().stroke(color(column.kind), lineWidth: 1)
                            Text(column.name + (state.map { "\n\($0.quantity)개" } ?? ""))
                                .font(.system(size: 10)).lineLimit(3).minimumScaleFactor(0.5).padding(2)
                        }
                        .frame(width: max(0, CGFloat(size.width) * scale), height: max(0, CGFloat(size.depth) * scale))
                        .offset(x: CGFloat(column.xMM) * scale, y: CGFloat(column.yMM) * scale)
                    }
                }
                .frame(width: width * scale, height: length * scale)
                .overlay(Rectangle().stroke(Color.primary, lineWidth: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            Text("차량 뒤쪽 · 갈색 쌀 / 주황 계란 / 보라 박스").font(.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("화물칸 평면도. 위쪽이 차량 앞쪽입니다. 위치별 수량은 아래 목록에서도 확인할 수 있습니다.")
    }
}

struct CargoResultView: View {
    let plan: DeliveryPlan
    let result: CargoResult
    @State private var selected = "depot"
    private var snapshot: CargoSnapshot? { result.snapshots.first { $0.visitID == selected } }
    var body: some View {
        List {
            Section {
                Picker("적재 상태", selection: $selected) {
                    ForEach(Array(result.snapshots.enumerated()), id: \.element.id) { index, s in
                        Text(index == 0 ? (s.visitID == "depot" ? "회사 출발" : "재계산 시작 · " + plan.name(s.visitID)) : "\(index). \(plan.name(s.visitID)) 작업 후").tag(s.visitID)
                    }
                }
                Text("등록 배치 기준 통과 · 파렛트 \(result.palletCount)장 유지").font(.caption)
                if let s = snapshot, let c = plan.cargo { CargoFloorMap(config: c, snapshot: s).frame(height: 360) }
            }
            if let s = snapshot {
                Section("남은 화물") {
                    ForEach(s.inventory) { item in Text("\(CargoKind.label(item.kind)) \(item.quantity)개") }
                    Text("마지막 거래처 작업 후 남은 매입품은 회사 도착 시 하차 전 재고입니다. 빈 높이만으로 추가 매입 가능량을 계산하지 않습니다.").font(.caption).foregroundColor(.secondary)
                }
                if !s.actions.isEmpty {
                    Section("이 거래처에서의 작업 순서") {
                        ForEach(Array(s.actions.enumerated()), id: \.offset) { index, action in
                            Text("\(index + 1). \(CargoActionText.text(action, config: plan.cargo ?? CargoPlan()))")
                                .font(.subheadline)
                        }
                    }
                }
                Section("위치별 아래 → 위") {
                    ForEach(s.columns) { column in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(column.name) · \(column.quantity)개 · 바닥 기준 \(Int(column.heightMM))mm").bold()
                            if column.lots.isEmpty { Text("화물 없음").foregroundColor(.secondary) }
                            ForEach(Array(column.lots.enumerated()), id: \.offset) { _, group in
                                Text("\(CargoKind.label(group.kind)) \(group.quantity)개 → \(plan.name(group.unloadAt))").font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { selected = result.snapshots.first?.visitID ?? "depot" }
        .navigationTitle("출발·방문별 적재 상태").navigationBarTitleDisplayMode(.inline)
    }
}
