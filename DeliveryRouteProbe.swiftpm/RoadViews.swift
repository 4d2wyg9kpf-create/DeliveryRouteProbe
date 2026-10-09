import SwiftUI

struct RoadSettingsView: View {
    @ObservedObject var store: PlannerStore
    @ObservedObject var browser: BrowserModel
    let openRoute: (String) -> Void
    @State private var fromID = "depot"
    @State private var toID = ""
    @State private var roadDraft: DeliveryLeg?
    private var policy: Binding<RoadPolicy> {
        Binding(get: { store.plan.road ?? RoadPolicy() }, set: { store.plan.road = $0 })
    }
    var body: some View {
        Form {
            Section("계산에 적용할 도로 조건") {
                Toggle("도로 조건 반영", isOn: policy.enabled)
                Toggle("가게 쪽 도착·출발", isOn: policy.requireCurb)
                Toggle("높이 조건", isOn: policy.requireHeight)
                Toggle("같은 경로의 1종 통행료 확인", isOn: policy.requireClass1Toll)
                RoadNumberRow(title: "차량 전체 높이(mm)", value: policy.vehicleHeightMM)
                RoadNumberRow(title: "추가 여유 높이(mm)", value: policy.clearanceMarginMM)
                Text("높이는 화물칸 내부 높이가 아닌 차량 전체 높이입니다. 켠 항목의 근거가 없는 경로는 계산에서 제외됩니다.").font(.caption)
            }
            Section("출발지·배송지·도착지 하역 위치") {
                ForEach(store.plan.nodes, id: \.id) { node in
                    NavigationLink {
                        StopRoadEditor(stopID: node.id, name: node.name, initial: store.plan.access(node.id) ?? StopRoadAccess(), browser: browser, openRoute: openRoute) { value in
                            store.plan.setAccess(value, id: node.id)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(node.name)
                            Text(store.plan.access(node.id)?.label ?? "하역 지점 미등록").font(.caption).foregroundColor(.secondary)
                            if let point = store.plan.access(node.id)?.curbPoint { Text(point.name).font(.caption) }
                        }
                    }
                }
                Text("중앙선이 있는 편도 2차로 이상은 네이버의 방향 처리를 사용합니다. 그 외 양방향 도로는 하역 직전 진입 지점과 출발 직후 진출 지점을 추가합니다. 일방통행은 허용 방향을 따릅니다.").font(.caption)
            }
            Section("하역 위치로 자동차 경로 검색") {
                Picker("출발", selection: $fromID) { ForEach(store.plan.nodes, id: \.id) { Text($0.name).tag($0.id) } }
                Picker("도착", selection: $toID) {
                    Text("선택").tag("")
                    ForEach(store.plan.nodes, id: \.id) { Text($0.name).tag($0.id) }
                }
                Button("이 하역 지점·방향으로 네이버 열기") {
                    do {
                        let request = try RoadBridge.request(store.plan, from: fromID, to: toID)
                        if request.ok, let url = request.url { openRoute(url) }
                        else { store.errorMessage = request.errors.joined(separator: "\n") }
                    } catch { store.errorMessage = error.localizedDescription }
                }.disabled(toID.isEmpty || fromID == toID)
                Text("높이 조건을 사용할 때는 지도 차량 설정의 2종 이상에서 높이를 \((store.plan.road?.vehicleHeightMM ?? 0) + (store.plan.road?.clearanceMarginMM ?? 0))mm 이상으로 저장합니다. 후보의 상세보기를 연 뒤 ‘화면 읽기’를 누르면 저장된 설정도 함께 읽습니다.").font(.caption)
                Button("읽은 상세 경로를 이 구간의 후보로 추가") { addCapture() }
                    .disabled(browser.capture == nil || toID.isEmpty || fromID == toID)
            }
            Section("도로 근거가 연결된 후보") {
                ForEach(store.plan.legs.filter { $0.road != nil }) { leg in
                    Button { roadDraft = leg } label: {
                        VStack(alignment: .leading) {
                            Text("\(store.plan.name(leg.fromID)) → \(store.plan.name(leg.toID))")
                            Text("\(leg.routeLabel ?? leg.sourceLabel) · \(leg.minutes)분").font(.caption)
                        }
                    }
                }
                Text("하역 지점이나 도로 유형을 바꾸면 이전 경로의 연결이 무효가 됩니다. 최종 도착 구간까지 등록해야 계산할 수 있습니다.").font(.caption)
            }
        }
        .sheet(item: $roadDraft) { leg in
            RoadLegEditor(leg: leg, plan: store.plan, browser: browser, onSave: store.saveLeg)
        }
        .onChange(of: store.plan.nodes.map(\.id)) { ids in
            if fromID != "depot" && !ids.contains(fromID) { fromID = "depot" }
            if toID != "depot" && !ids.contains(toID) { toID = "" }
        }
    }
    private func addCapture() {
        guard let capture = browser.capture, let data = browser.exportData,
              let route = capture.candidates.first(where: \.selected), let minutes = route.durationMinutes,
              minutes.isFinite, (0...2880).contains(minutes) else { return }
        var leg = DeliveryLeg()
        leg.fromID = fromID; leg.toID = toID; leg.minutes = Int(minutes.rounded(.up)); leg.source = "naver"
        leg.vehicleClass = capture.vehicleClass; leg.capturedAt = capture.capturedAt
        leg.distanceMeters = route.distanceMeters; leg.tollWon = route.tollWon; leg.routeLabel = route.label
        leg.arrivalSideText = capture.detail.arrivalSideText; leg.pageURL = capture.pageURL
        leg.captureJSON = String(decoding: data, as: UTF8.self)
        do {
            let changed = try RoadBridge.attach(store.plan, leg: leg)
            if changed.ok, let value = changed.leg { roadDraft = value }
            else { store.errorMessage = changed.errors.joined(separator: "\n") }
        } catch { store.errorMessage = error.localizedDescription }
    }
}

struct RoadNumberRow: View {
    let title: String
    @Binding var value: Int
    var body: some View {
        HStack { Text(title); Spacer(); IntegerInput(title: title, value: $value).frame(width: 100, height: 44) }
    }
}

private struct PointSlot: Identifiable {
    var id: String
    var title: String
}

private struct StopRoadEditor: View {
    let stopID: String
    let name: String
    @State var draft: StopRoadAccess
    @ObservedObject var browser: BrowserModel
    let openRoute: (String) -> Void
    let onSave: (StopRoadAccess) -> Void
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var pointSlot: PointSlot?
    @State private var showBikeImport = false
    @State private var entranceError: String?
    @State private var entranceImportID: UUID?
    init(stopID: String, name: String, initial: StopRoadAccess, browser: BrowserModel, openRoute: @escaping (String) -> Void, onSave: @escaping (StopRoadAccess) -> Void) {
        self.stopID = stopID; self.name = name; _draft = State(initialValue: initial); self.browser = browser; self.openRoute = openRoute; self.onSave = onSave
    }
    private var entranceConfirmed: Binding<Bool> {
        Binding(get: { draft.bikeEntrance?.entranceConfirmed ?? false }, set: { value in
            draft.bikeEntrance?.entranceConfirmed = value
            draft.curbConfirmed = false
        })
    }
    private var curbConfirmed: Binding<Bool> {
        Binding(get: { draft.curbConfirmed }, set: { value in
            draft.curbConfirmed = value
            draft.curbEntranceToken = value ? draft.entrancePoint?.token : nil
        })
    }
    var body: some View {
        Form {
            Section("차량이 정차할 위치") {
                Picker("도로 유형", selection: $draft.roadType) {
                    Text("선택해 주세요").tag("")
                    Text("중앙선·편도 2차로 이상").tag("naverMultiLane")
                    Text("그 외 양방향 도로").tag("twoWayNarrow")
                    Text("일방통행").tag("oneWay")
                }
                pointButton("curb", "차량 하역 지점", draft.curbPoint)
                Toggle("실제 가게 앞 하역 위치임을 확인", isOn: curbConfirmed)
                    .disabled(draft.curbPoint == nil || (draft.bikeEntrance != nil && draft.bikeEntrance?.entranceConfirmed != true))
                Text("건물 검색 결과 대신 차량이 서야 하는 도로변 지점을 지정합니다. 자전거 도착 위치는 입구를 찾는 참고로 사용하고, 차량 하역 위치를 별도로 저장합니다.").font(.caption)
            }
            Section("가게 입구 참고") {
                Button("읽은 자전거 종점 가져오기") { showBikeImport = true }
                    .disabled(browser.bikeCapture == nil)
                if let read = browser.bikeCapture { Text("현재 후보: \(read.destination.name)").font(.caption) }
                pointButton("entrance", "입구 지점 직접 지정", draft.entrancePoint)
                if let binding = draft.bikeEntrance {
                    Text("자전거 검색 목적지: \(binding.capture.destination.name)").font(.caption)
                    Text("경로 끝점과 목적지 표시의 차이: 약 \(binding.capture.destinationGapMeters, specifier: "%.1f")m").font(.caption)
                    Toggle("이 거래처의 실제 입구임을 확인", isOn: entranceConfirmed)
                    Button("저장한 입구 후보를 지도에서 보기") { openRoute(binding.capture.previewURL) }
                    Button("확인한 입구 좌표를 하역 후보로 사용") {
                        draft.curbPoint = draft.entrancePoint
                        draft.curbEntranceToken = draft.entrancePoint?.token
                        draft.curbConfirmed = false
                    }.disabled(!binding.entranceConfirmed)
                    Text("자전거가 도착할 수 있어도 차량이 들어갈 수 있다고 간주하지 않습니다. 차량이 설 도로변이 다르면 위의 차량 하역 지점을 직접 지정하세요.").font(.caption)
                } else {
                    Text("지도 탭의 ‘자전거 종점 읽기’가 실제 경로 선의 끝을 읽습니다. 직접 지정은 길찾기 주소의 장소 좌표를 가져오므로 실제 입구인지 확인해야 합니다.").font(.caption)
                }
                if let entranceError = entranceError { Text(entranceError).foregroundColor(.red).font(.caption) }
            }
            if draft.roadType == "twoWayNarrow" {
                Section("가게 쪽 차로의 진행 순서") {
                    pointButton("approach", "하역 직전 통과 지점", draft.approachPoint)
                    Text("진입 지점 → 하역 지점 → 진출 지점").font(.caption)
                    pointButton("departure", "출발 직후 통과 지점", draft.departurePoint)
                    Text("교차로·회전 가능한 위치를 보고 실제로 통과할 도로 위에 지정합니다. 경로 후보의 출발·도착과 회전 안내를 확인한 기록을 함께 저장합니다.").font(.caption)
                }
            }
            Section("위치 설명") { NativeMemoEditor(text: $draft.note).frame(height: 100) }
        }
        .navigationTitle(name)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("저장") { inputs.finishEditing(); onSave(draft); dismiss() } } }
        .sheet(item: $pointSlot) { slot in
            MapPointPicker(title: slot.title, url: browser.currentPageAddress) { point in
                draft.curbConfirmed = false
                draft.curbEntranceToken = nil
                switch slot.id {
                case "curb": draft.curbPoint = point
                case "approach": draft.approachPoint = point
                case "departure": draft.departurePoint = point
                default: draft.entrancePoint = point; draft.bikeEntrance = nil
                }
            }
        }
        .sheet(isPresented: $showBikeImport) {
            NavigationStack {
                Form {
                    Section("연결할 거래처") { Text(name).bold() }
                    if let capture = browser.bikeCapture {
                        Section("읽은 자전거 경로") {
                            Text("\(capture.start.name) → \(capture.destination.name)")
                            Text(capture.arrivalSideText).font(.caption)
                            Text("입구 후보를 저장해도 차량 하역 위치 확인은 새로 필요합니다.").font(.caption)
                            Button("이 거래처의 입구 후보로 가져오기") { importEntrance(capture) }
                                .disabled(entranceImportID != nil)
                            if entranceImportID != nil { ProgressView("지도 목적지 확인 중") }
                        }
                    } else { Text("지도 목적지가 바뀌었습니다. 자전거 종점을 다시 읽어 주세요.") }
                }.navigationTitle("거래처와 종점 연결")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { showBikeImport = false } } }
            }
        }
        .onChange(of: draft.roadType) { _ in draft.curbConfirmed = false }
        .onChange(of: showBikeImport) { visible in if !visible { entranceImportID = nil } }
    }
    private func importEntrance(_ capture: BikeEntranceCapture) {
        let id = UUID()
        entranceImportID = id
        browser.verifyBikeCapture(capture) { valid in
            guard entranceImportID == id, showBikeImport else { return }
            defer { entranceImportID = nil; showBikeImport = false }
            guard valid else {
                entranceError = "지도 검색 장소나 후보가 바뀌었습니다. 자전거 종점을 다시 읽어 주세요."
                return
            }
            do {
                let change = try RoadBridge.entrance(draft, capture: capture, stopID: stopID, currentURL: browser.currentPageAddress)
                if change.ok, let access = change.access { draft = access; entranceError = nil }
                else { entranceError = change.errors.joined(separator: "\n") }
            } catch { entranceError = error.localizedDescription }
        }
    }
    private func pointButton(_ id: String, _ title: String, _ point: MapRoutePoint?) -> some View {
        Button { pointSlot = PointSlot(id: id, title: title) } label: {
            HStack { Text(title); Spacer(); Text(point?.name ?? "지도 지점 가져오기").foregroundColor(.secondary) }
        }
    }
}

private struct MapPointPicker: View {
    let title: String
    @State var url: String
    let onSelect: (MapRoutePoint) -> Void
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var route: ParsedMapRoute?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("현재 지도에 지정한 지점") {
                    Text("길찾기의 출발·경유·도착 지점 중 저장할 지점을 선택합니다. 지도 탭에서 정확한 위치를 지정한 후 가져오세요.").font(.caption)
                    NativeTextField("네이버 길찾기 주소", text: $url, keyboard: .URL).frame(minHeight: 44)
                    Button("주소의 지점 읽기") { inputs.finishEditing(); read() }
                    if let error = error { Text(error).foregroundColor(.red).font(.caption) }
                    if let route = route {
                        ForEach(Array(route.points.enumerated()), id: \.offset) { index, point in
                            Button("\(index == 0 ? "출발" : index == route.points.count - 1 ? "도착" : "경유 \(index)"): \(point.name)") { inputs.finishEditing(); onSelect(point); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } } }
            .onAppear { read() }
            .onChange(of: url) { _ in route = nil }
        }
    }
    private func read() {
        do { route = try RoadBridge.points(url.trimmingCharacters(in: .whitespacesAndNewlines)); error = nil }
        catch { route = nil; self.error = error.localizedDescription }
    }
}

struct RoadLegEditor: View {
    @State private var draft: DeliveryLeg
    let plan: DeliveryPlan
    @ObservedObject var browser: BrowserModel
    let onSave: (DeliveryLeg) -> Void
    let saveTitle: String
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var check: RoadCheck?
    private var expiredTMap: Bool {
        guard draft.source == "tmap" else { return false }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let text = draft.apiExpiresAt, let expiry = format.date(from: text) else { return true }
        return Date() >= expiry
    }
    init(leg: DeliveryLeg, plan: DeliveryPlan, browser: BrowserModel, saveTitle: String = "저장", onSave: @escaping (DeliveryLeg) -> Void) {
        _draft = State(initialValue: leg); self.plan = plan; self.browser = browser; self.saveTitle = saveTitle; self.onSave = onSave
    }
    private func flag(_ key: WritableKeyPath<LegRoadEvidence, Bool>) -> Binding<Bool> {
        Binding(get: { draft.road?[keyPath: key] ?? false }, set: { draft.road?[keyPath: key] = $0 })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("연결된 자동차 경로") {
                    Text("\(plan.name(draft.fromID)) → \(plan.name(draft.toID))").bold()
                    Text("\(draft.routeLabel ?? "경로") · \(draft.minutes)분 · \(draft.vehicleClass ?? "차종 미확인")")
                    Text(draft.arrivalSideText ?? "도착 방향 문구 없음").font(.caption)
                    if let time = draft.capturedAt { Text(time).font(.caption) }
                    if let provider = draft.tmapProvider, !expiredTMap {
                        TMapLegMap(provider: provider).frame(height: 280)
                    }
                    if expiredTMap { Text("티맵 경로의 24시간 유효기간이 끝났습니다. 새로 요청한 자료로 확인해 주세요.").font(.caption).foregroundColor(.orange) }
                    if draft.road == nil {
                        Button("현재 하역 지점에 연결") {
                            do { apply(try RoadBridge.attach(plan, leg: draft)) }
                            catch { message = error.localizedDescription }
                        }
                        .disabled(expiredTMap)
                    }
                }
                if draft.road != nil {
                    Section("출발·도착 방향") {
                        if draft.source == "tmap" || plan.access(draft.fromID)?.roadType == "twoWayNarrow" {
                            Toggle(draft.source == "tmap" ? "티맵 경로가 실제 하역 차로에서 출발함" : "가게 쪽 차로에서 진출 지점으로 출발함", isOn: flag(\.departureConfirmed))
                        }
                        if draft.source == "tmap" || plan.access(draft.toID)?.roadType == "twoWayNarrow" {
                            Toggle(draft.source == "tmap" ? "티맵 경로가 실제 하역 차로로 도착함" : "진입 지점에서 가게 쪽 차로로 도착함", isOn: flag(\.arrivalConfirmed))
                        }
                        if draft.source == "tmap" || plan.access(draft.fromID)?.roadType == "twoWayNarrow" || plan.access(draft.toID)?.roadType == "twoWayNarrow" {
                            Toggle("경유지 전후의 회전·통행 방향을 확인함", isOn: flag(\.legalDirectionConfirmed))
                        }
                        Text(draft.source == "tmap" ? "위 티맵 실제 경로의 출발·도착 차로와 회전·통행 방향을 직접 확인합니다. 일방통행은 등록한 도로 규칙을 따릅니다. 티맵 API가 도착 방향을 확인했다고 자동 처리하지 않습니다." : "중앙선·편도 2차로 이상은 네이버의 방향 처리를 반영합니다. 양방향 도로에서 ‘도착지는 왼쪽’인 경로는 제외합니다. 일방통행은 가게 쪽 조건의 예외입니다.").font(.caption)
                    }
                    Section("높이") {
                        Text(draft.source == "tmap" ? "티맵 전체 경로의 최소 통과 높이를 확인합니다." : draft.road?.heightBasis == "naverSetting" ? "저장된 네이버 높이 설정: \(draft.road?.heightMM ?? 0)mm" : "네이버 높이 설정 근거 없음")
                        if draft.road?.heightBasis != "naverSetting" {
                            Toggle("전체 구간의 최소 통과 높이를 직접 확인", isOn: Binding(get: { draft.road?.heightBasis == "minimumClearance" }, set: { value in
                                draft.road?.heightBasis = value ? "minimumClearance" : "none"; draft.road?.heightConfirmed = value
                            }))
                            if draft.road?.heightBasis == "minimumClearance" {
                                RoadNumberRow(title: "확인한 최소 높이(mm)", value: Binding(get: { draft.road?.heightMM ?? 0 }, set: { draft.road?.heightMM = $0 }))
                                NativeTextField("전체 구간 높이를 확인한 근거", text: Binding(get: { draft.road?.heightNote ?? "" }, set: { draft.road?.heightNote = $0 })).frame(minHeight: 44)
                            }
                        }
                        Text(draft.source == "tmap" ? "화물차 치수를 API에 보냈다는 것만으로 높이 확인을 완료하지 않습니다. 전체 경로의 실제 통과 높이와 확인 근거를 남깁니다." : "지도 설정 근거는 화면 읽기로 기록합니다. 높이를 바꾸면 변경된 조건으로 경로를 다시 읽어야 합니다.").font(.caption)
                    }
                    Section("이 경로의 1종 통행료") {
                        if let fee = draft.road?.class1TollWon { Text("\(fee)원 · \(draft.road?.fareSource == "matchingGuides" ? "경로 확인 대기" : "연결됨")") }
                        else { Text("미확인") }
                        if draft.source != "tmap" {
                        Button("마지막으로 읽은 1종 상세 경로의 요금 연결") {
                            guard let data = browser.exportData else { return }
                            do { apply(try RoadBridge.fare(draft, capture: data)) }
                            catch { message = error.localizedDescription }
                        }.disabled(browser.exportData == nil)
                        if draft.road?.fareSource == "matchingGuides" || draft.road?.fareSource == "confirmedSameRoute" {
                            Toggle("높이 경로와 1종 경로가 실제로 같음을 확인", isOn: Binding(get: { draft.road?.fareSource == "confirmedSameRoute" }, set: { draft.road?.fareSource = $0 ? "confirmedSameRoute" : "matchingGuides" }))
                        }
                        Text("지도에서 1종으로 바꾼 뒤 같은 도로를 지나는 후보의 상세보기를 읽습니다. 모든 지정 지점·거리·상세 안내가 일치해야 연결되며, 지도 선형까지 같은지 확인한 후 확정합니다.").font(.caption)
                        } else {
                            Text("1종으로 요청한 동일 티맵 경로의 통행료를 사용합니다. 별도 통행료 API 호출은 없습니다.").font(.caption)
                        }
                    }
                }
                Section("계산 포함 여부") {
                    Button("현재 조건으로 확인") { refresh() }
                    if let check = check {
                        Text(check.eligible ? "현재 켠 도로 조건을 충족한 기록입니다." : check.reasons.joined(separator: "\n"))
                            .font(.caption).foregroundColor(check.eligible ? .green : .orange)
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundColor(.orange) }
                    Text("근거가 부족한 후보도 보관할 수 있습니다. 도로 조건을 켜면 미확인 후보는 계산에서 제외됩니다.").font(.caption)
                }
            }
            .navigationTitle("경로 후보 확인").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saveTitle) { inputs.finishEditing(); onSave(draft); dismiss() }.disabled(expiredTMap) }
            }
            .onAppear { refresh() }
            .onChange(of: try? RoadBridge.json(draft)) { _ in check = nil }
        }
    }
    private func refresh() {
        if expiredTMap { check = nil; message = "만료된 티맵 자료는 새 경로 확인에 사용할 수 없습니다."; return }
        do { check = try RoadBridge.inspect(plan, leg: draft) }
        catch { message = error.localizedDescription }
    }
    private func apply(_ result: RoadChange) {
        if result.ok, let value = result.leg { draft = value; message = result.note ?? "연결했습니다." }
        else { message = result.errors.joined(separator: "\n") }
        refresh()
    }
}
