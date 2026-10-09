import SwiftUI
import MapKit

struct NaverPlaceConnectionButton: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject var planner: PlannerStore
    @ObservedObject var browser: BrowserModel
    @State private var draft: NaverPlaceCapture?
    var body: some View {
        Group {
            if let capture = browser.placeCapture {
                Button("읽은 네이버 장소를 배송계획에 연결") { inputs.finishEditing(); draft = capture }
                    .disabled(planner.isComputing || browser.isReadingPlace)
            }
        }
        .sheet(item: $draft) { capture in
            NaverPlaceImportView(capture: capture, planner: planner, browser: browser)
        }
    }
}

struct NaverPlaceReadPanel: View {
    let capture: NaverPlaceCapture
    @ObservedObject var planner: PlannerStore
    @ObservedObject var browser: BrowserModel
    @EnvironmentObject private var customers: NaverCustomerStore
    @State private var error: String?
    @State private var resolving = false
    @State private var showAPISettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("읽은 네이버 장소", systemImage: "mappin.and.ellipse").font(.headline)
            Text(capture.name).bold()
            if !capture.preferredAddress.isEmpty { Text(capture.preferredAddress).font(.caption) }
            if !capture.jibunAddress.isEmpty { Text("지번 \(capture.jibunAddress)").font(.caption) }
            if let point = capture.coordinate {
                Text("경도 \(point.longitude, specifier: "%.6f") · 위도 \(point.latitude, specifier: "%.6f")").font(.caption)
                if let provider = capture.geocodeProvider { Text("좌표 제공 · \(provider)").font(.caption).foregroundColor(.secondary) }
                if let resolution = capture.screenResolutionMeters {
                    Text("화면 판독 간격 약 \(resolution, specifier: "%.1f")m · 실제 지도 정확도와는 다릅니다.").font(.caption2).foregroundColor(.secondary)
                }
            } else {
                Text(capture.coordinateIssue).font(.caption).foregroundColor(.orange)
                Button(resolving ? "좌표 조회 중…" : "네이버 API로 좌표 조회") {
                    resolving = true; error = nil
                    Task {
                        defer { resolving = false }
                        do {
                            let value = try await NaverAPIStore.shared.resolve(capture)
                            let current = try await NaverWebReader.root(browser.webView)
                            guard current["selectionKey"] as? String == capture.selectionKey else { throw PlannerFailure.message("선택 장소가 바뀌었습니다. 다시 읽어 주세요.") }
                            browser.placeCapture = value
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(resolving || NaverAPIStore.shared.isBusy)
                Button("네이버 API 키 설정") { showAPISettings = true }.disabled(resolving)
            }
            Button("거래처 목록에 저장") {
                do { try customers.save(capture); error = nil; browser.status = "거래처 목록에 저장했습니다. 이번 배송에 나갈 곳은 목록에서 체크하세요." }
                catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(capture.coordinate == nil)
            NaverPlaceConnectionButton(planner: planner, browser: browser)
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            Text("연결 전에 현재 선택 장소를 다시 확인합니다. 검색 표식을 차량 정차 위치로 사용할지는 연결 화면에서 선택합니다.").font(.caption2).foregroundColor(.secondary)
        }.padding(10).background(Color.blue.opacity(0.08)).cornerRadius(8)
            .sheet(isPresented: $showAPISettings) { NaverAPISettingsView(api: NaverAPIStore.shared) }
    }
}

private struct NaverPlaceImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inputs: NativeInputSession
    @EnvironmentObject private var customers: NaverCustomerStore
    let capture: NaverPlaceCapture
    @ObservedObject var planner: PlannerStore
    @ObservedObject var browser: BrowserModel
    @State private var targetID = "new"
    @State private var name: String
    @State private var address: String
    @State private var useCoordinate: Bool
    @State private var curbConfirmed = false
    @State private var isConnecting = false
    @State private var connectID: UUID?
    @State private var error: String?
    init(capture: NaverPlaceCapture, planner: PlannerStore, browser: BrowserModel) {
        self.capture = capture; self.planner = planner; self.browser = browser
        _name = State(initialValue: capture.name)
        _address = State(initialValue: capture.preferredAddress)
        _useCoordinate = State(initialValue: capture.coordinate != nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("선택한 네이버 장소") {
                    Text(capture.name).bold()
                    if !capture.preferredAddress.isEmpty { Text(capture.preferredAddress) }
                    if !capture.jibunAddress.isEmpty { Text("지번 \(capture.jibunAddress)").font(.caption) }
                    if let point = capture.coordinate {
                        Map {
                            Marker(capture.name, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                        }.frame(height: 200)
                        Text("경도 \(point.longitude, specifier: "%.6f") · 위도 \(point.latitude, specifier: "%.6f")").font(.caption)
                        if let provider = capture.geocodeProvider { Text("좌표 제공 · \(provider)").font(.caption).foregroundColor(.secondary) }
                if let resolution = capture.screenResolutionMeters {
                            Text("표식 화면 판독 간격 약 \(resolution, specifier: "%.1f")m").font(.caption)
                        }
                    } else { Text(capture.coordinateIssue).font(.caption).foregroundColor(.orange) }
                }
                Section("배송계획에 연결") {
                    Picker("연결할 거래처", selection: $targetID) {
                        if planner.plan.visits.count < 30 { Text("새 거래처").tag("new") }
                        ForEach(planner.plan.nodes, id: \.id) { node in Text(node.name).tag(node.id) }
                    }
                    if targetID == "new" {
                        NativeTextField("거래처 이름", text: $name).frame(minHeight: 44)
                    }
                    Picker("가져올 정보", selection: $useCoordinate) {
                        if capture.coordinate != nil { Text("좌표와 주소").tag(true) }
                        Text("주소만").tag(false)
                    }
                    NativeTextField("배송 주소·상세주소", text: $address).frame(minHeight: 44)
                    if useCoordinate {
                        Toggle("선택한 거래처의 실제 차량 정차 위치임을 확인", isOn: $curbConfirmed)
                        Text("학교 건물 중앙 등 차량이 서는 곳과 다른 표식이면 주소만 연결하고 실제 하역 위치를 따로 지정하세요.").font(.caption).foregroundColor(.secondary)
                        if targetID != "new", TMapBridge.coordinate(planner.plan, id: targetID) != nil {
                            Text("좌표가 바뀌면 이전 경로·이동시간은 기록을 남기고 계산에서 제외합니다. 새 위치의 경로를 확인하거나 티맵을 다시 요청해 주세요.").font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        Text("기존 차량 정차 좌표는 유지합니다. 좌표가 없는 거래처는 하역 위치를 지정한 뒤 티맵을 요청할 수 있습니다.").font(.caption).foregroundColor(.secondary)
                    }
                    Text("기존 거래처에 연결하면 이름·배송 시간·주문 수량은 유지합니다. 장소 읽기와 연결은 티맵 무료 횟수를 사용하지 않습니다.").font(.caption)
                }
                if let error = error { Text(error).foregroundColor(.red).font(.caption) }
                Button(isConnecting ? "선택 장소 확인 중…" : "배송계획에 연결") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting || planner.isComputing || browser.isReadingPlace || (useCoordinate && !curbConfirmed) || (targetID == "new" && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .navigationTitle("네이버 장소 연결")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { inputs.finishEditing(); dismiss() }.disabled(isConnecting) } }
            .interactiveDismissDisabled(isConnecting)
            .onAppear {
                if planner.plan.naverOrigin?.selectionKey == capture.selectionKey || planner.plan.originName.replacingOccurrences(of: " ", with: "") == capture.name.replacingOccurrences(of: " ", with: "") { targetID = "depot" }
                else if let matched = planner.plan.visits.first(where: { $0.naverPlace?.selectionKey == capture.selectionKey }) { targetID = matched.id }
                else if planner.plan.visits.count >= 30 { targetID = planner.plan.visits.first?.id ?? "depot" }
            }
            .onChange(of: targetID) { _, _ in curbConfirmed = false }
            .onChange(of: useCoordinate) { _, _ in curbConfirmed = false }
            .onDisappear { connectID = nil }
        }
    }
    private func connect() {
        inputs.finishEditing(); error = nil
        guard planner.autoSaveEnabled else { error = "저장된 계획의 읽기 오류를 먼저 해결하거나 계획을 새로 불러와 주세요."; return }
        do {
            let expected = try TMapBridge.fingerprintData(planner.plan)
            let id = UUID(); connectID = id; isConnecting = true
            browser.verifySelectedPlace(capture, useCoordinate: useCoordinate) { same in
                guard connectID == id else { return }
                isConnecting = false; connectID = nil
                do {
                    guard same else { throw PlannerFailure.message("네이버 선택 장소·주소가 바뀌었거나 확인할 수 없습니다. 지도에서 다시 읽어 주세요.") }
                    guard try TMapBridge.fingerprintData(planner.plan) == expected else { throw PlannerFailure.message("확인 중 배송계획이 변경됐습니다. 연결 대상을 다시 선택해 주세요.") }
                    var newVisit = DeliveryVisit(); newVisit.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = try NaverPlaceBridge.call("attach", ["plan": try TMapBridge.object(planner.plan), "capture": try TMapBridge.object(capture),
                        "targetID": targetID, "newVisit": try TMapBridge.object(newVisit), "useCoordinate": useCoordinate,
                        "curbConfirmed": curbConfirmed, "requestAddress": address.trimmingCharacters(in: .whitespacesAndNewlines)], as: NaverPlaceAttachment.self)
                    planner.errorMessage = nil; planner.plan = value.plan; planner.saveNow()
                    try customers.remember(planner.plan)
                    browser.status = value.coordinateChanged ? "네이버 장소를 연결했습니다. 위치가 바뀐 구간은 새 경로를 확인해 주세요." : "네이버 장소를 배송계획에 연결했습니다."
                    if planner.errorMessage == nil { dismiss() }
                    else { error = planner.errorMessage }
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
