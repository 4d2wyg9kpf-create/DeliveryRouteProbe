import SwiftUI

struct NaverCustomerCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var customers: NaverCustomerStore
    @ObservedObject var planner: PlannerStore
    @ObservedObject var browser: BrowserModel
    @State private var selectedIDs = Set<String>()
    @State private var curbConfirmed = false
    @State private var error: String?
    @State private var deleting: NaverCustomerRecord?
    @State private var confirmDelete = false
    @State private var originID = "current"
    @State private var endMode = "return"
    @State private var destinationID = ""
    var body: some View {
        NavigationStack {
            List {
                Section("출발지 · 최종 도착지") {
                    Picker("출발지", selection: $originID) {
                        Text("현재 출발지: \(planner.plan.originName)").tag("current")
                        ForEach(customers.records) { Text($0.name).tag($0.id) }
                    }
                    Picker("도착 방식", selection: $endMode) {
                        Text("출발지로 복귀").tag("return")
                        Text("목록에서 도착지 선택").tag("custom")
                        Text("마지막 배송지에서 종료").tag("last")
                    }
                    if endMode == "custom" {
                        Picker("최종 도착지", selection: $destinationID) {
                            Text("도착지를 선택하세요").tag("")
                            ForEach(customers.records) { Text($0.name).tag($0.id) }
                        }
                    }
                    if endMode == "last" { Text("티맵 최적화는 고정된 최종 도착지가 필요합니다. 이 방식에서는 등록한 이동시간으로 배송계획을 계산합니다.").font(.caption).foregroundColor(.secondary) }
                    Text("출발지·최종 도착지와 체크한 배송지는 각각 지정합니다. 출발지나 도착지에서도 배송 작업이 있으면 그 장소를 체크하세요.").font(.caption)
                }
                Section("이번에 배송할 거래처") {
                    Text("전체 목록은 보관하고, 체크한 곳만 이번 배송에 방문합니다. 최대 30곳을 선택할 수 있습니다.").font(.caption)
                    HStack {
                        Text("\(selectedIDs.count)곳 선택 / 전체 \(customers.records.count)곳")
                        Spacer()
                        Button("선택 해제") { selectedIDs.removeAll(); curbConfirmed = false }.buttonStyle(.borderless)
                    }
                }
                if let message = customers.errorMessage { Text(message).foregroundColor(.red).font(.caption) }
                if customers.records.isEmpty { Text("네이버에서 장소를 읽거나 저장 목록을 가져오면 여기에 보관됩니다.").foregroundColor(.secondary) }
                ForEach(customers.records) { record in
                    HStack(spacing: 12) {
                        Button {
                            if selectedIDs.contains(record.id) { selectedIDs.remove(record.id) }
                            else if selectedIDs.count < 30 { selectedIDs.insert(record.id) }
                            else { error = "이번 배송은 최대 30곳까지 선택할 수 있습니다." }
                            curbConfirmed = false
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundColor(selectedIDs.contains(record.id) ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name).foregroundColor(.primary)
                                    if let capture = record.capture, !capture.preferredAddress.isEmpty { Text(capture.preferredAddress).font(.caption).foregroundColor(.secondary) }
                                    if let coordinate = record.template.tmapCoordinate ?? record.capture?.coordinate {
                                        Text("경도 \(coordinate.longitude, specifier: "%.6f") · 위도 \(coordinate.latitude, specifier: "%.6f")").font(.caption2).foregroundColor(.secondary)
                                    } else { Text("좌표 지정 필요").font(.caption2).foregroundColor(.orange) }
                                    if !record.folders.isEmpty { Text(record.folders.joined(separator: " · ")).font(.caption2).foregroundColor(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.borderless).accessibilityLabel("\(record.name), \(selectedIDs.contains(record.id) ? "선택됨" : "선택 안 됨")")
                        Button(role: .destructive) { deleting = record; confirmDelete = true } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("\(record.name) 거래처 목록에서 삭제")
                    }
                }
                Section {
                    if needsCoordinateConfirmation {
                        Toggle("선택한 좌표에서 실제로 정차할 수 있음을 확인", isOn: $curbConfirmed)
                        Text("건물 중앙에 찍힌 표식이면 실제 하역 위치를 지정해 주세요.").font(.caption).foregroundColor(.secondary)
                    }
                    if let error { Text(error).foregroundColor(.red).font(.caption) }
                    Button("선택한 \(selectedIDs.count)곳으로 이번 배송계획 저장") {
                        do { try customers.applySelection(selectedIDs, planner: planner, curbConfirmed: curbConfirmed, originID: originID, endMode: endMode, destinationID: destinationID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                        .disabled(planner.isComputing || (needsCoordinateConfirmation && !curbConfirmed) || (endMode == "custom" && destinationID.isEmpty))
                }
            }
            .navigationTitle("거래처 목록 · 이번 배송 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .onAppear {
                do { try customers.remember(planner.plan) } catch { self.error = error.localizedDescription }
                selectedIDs = Set(customers.records.filter { record in
                    planner.plan.visits.contains { $0.id == record.template.id || (record.capture != nil && $0.naverPlace?.selectionKey == record.capture?.selectionKey) }
                }.map(\.id))
                endMode = planner.plan.returnToOrigin ? (planner.plan.destination == nil ? "return" : "custom") : "last"
                destinationID = planner.plan.destination?.customerID ?? ""
            }
            .confirmationDialog("거래처 목록에서 삭제", isPresented: $confirmDelete, titleVisibility: .visible) {
                if let record = deleting {
                    Button("\(record.name) 삭제", role: .destructive) {
                        do {
                            // Remove any current visit too, so it cannot reappear on migration.
                            try customers.remove(record.id)
                            for visit in planner.plan.visits where visit.id == record.template.id || (record.capture != nil && visit.naverPlace?.selectionKey == record.capture?.selectionKey) { planner.removeVisit(visit.id) }
                            if planner.plan.originCustomerID == record.id || (record.capture != nil && planner.plan.naverOrigin?.selectionKey == record.capture?.selectionKey) || record.template.id == "origin-depot" { planner.clearOriginLocation() }
                            if planner.plan.destination?.customerID == record.id { planner.clearDestination() }
                            selectedIDs.remove(record.id)
                            if originID == record.id { originID = "current" }; if destinationID == record.id { destinationID = "" }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("앱의 거래처 목록과 이번 배송계획에서 지웁니다. 네이버에 저장된 원본 목록은 유지합니다.") }
        }
    }
    private var needsCoordinateConfirmation: Bool {
        customers.records.contains { record in
            let endpoint = originID == record.id || endMode == "custom" && destinationID == record.id
            if endpoint && record.capture?.coordinate != nil && record.template.tmapCoordinate == nil && record.template.roadAccess?.curbConfirmed != true { return true }
            guard selectedIDs.contains(record.id), record.capture?.coordinate != nil else { return false }
            let existing = planner.plan.visits.first { $0.id == record.template.id || $0.naverPlace?.selectionKey == record.capture?.selectionKey }
            return existing == nil || TMapBridge.coordinate(planner.plan, id: existing!.id) == nil
        }
    }
}

struct NaverSavedListStatusView: View {
    @ObservedObject var browser: BrowserModel
    let openCustomers: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if browser.waitingForSavedFolder {
                Text("가져올 네이버 저장 폴더를 선택하세요. 선택한 폴더 전체를 자동으로 가져옵니다.").font(.caption)
            }
            if !browser.savedListProgress.isEmpty { Text(browser.savedListProgress).font(.caption) }
            HStack {
                if browser.isImportingSavedList || browser.waitingForSavedFolder {
                    if browser.isImportingSavedList { ProgressView() }
                    Button("가져오기 중단", action: browser.cancelSavedListImport)
                }
                Button("거래처 목록 · 이번 배송 선택", action: openCustomers)
            }.font(.caption)
            if let report = browser.savedListReport, !report.failures.isEmpty {
                DisclosureGroup("가져오지 못한 \(report.failures.count)곳") {
                    ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in Text(failure).font(.caption2).foregroundColor(.orange) }
                }.font(.caption)
            }
        }.padding(8)
    }
}
