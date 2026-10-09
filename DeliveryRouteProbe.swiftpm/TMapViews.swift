import SwiftUI
import MapKit
import Combine

private struct TMapLocationDraft: Identifiable {
    var id: String
    var name: String
    var coordinate: TMapCoordinate?
}

struct TMapScreen: View {
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject var store: TMapStore
    @ObservedObject var planner: PlannerStore
    let openNaver: (String) -> Void
    @State private var showSettings = false
    @State private var locationDraft: TMapLocationDraft?
    @State private var usageDraft: Int?
    @State private var showUsage = false
    @State private var usageText = ""
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                requestSection
                timingSection
                quotaSection
                if let error = store.errorMessage {
                    Section { Text(error).foregroundColor(.red).font(.caption) }
                }
                if let route = store.route, store.routeIsValid {
                    routeSection(route)
                }
                locationsSection
            }
            .navigationTitle("티맵 배송경로 \(DeliveryAppInfo.version)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { inputs.finishEditing(); showSettings = true } label: { Label("티맵 설정", systemImage: "gearshape") }
                        .disabled(store.isOptimizing || store.isRefreshing)
                }
            }
            .sheet(isPresented: $showSettings) { TMapSettingsView(store: store) }
            .sheet(item: $locationDraft) { draft in
                TMapLocationEditor(name: draft.name, coordinate: draft.coordinate, isDepot: draft.id == "depot") { coordinate in
                    var next = planner.plan
                    if draft.id == "depot" { next.tmapOrigin = coordinate }
                    else if let index = next.visits.firstIndex(where: { $0.id == draft.id }) { next.visits[index].tmapCoordinate = coordinate }
                    planner.plan = next
                }
            }
            .sheet(isPresented: $showUsage) { usageEditor }
            .task { await store.refreshClock() }
            .onReceive(timer) { _ in store.tick() }
        }
    }
    private var requestSection: some View {
        Section("경로 최적화") {
            Text("\(planner.plan.originName) → 거래처 \(planner.plan.visits.count)곳 → 회사 복귀").font(.headline)
            Text("운행 \(planner.plan.planDate) · \(PlannerClock.text(planner.plan.startMinute)) 출발").font(.caption)
            if let quota = store.quota(for: planner.plan.visits.count) {
                Text("선택 API: \(quota.label) · 무료 \(quota.remaining)/\(quota.limit)회 남음")
                if quota.blocked { Text("무료 한도 소진 · \(resetTime(quota.resetAtMillis)) 이후 재개").foregroundColor(.orange) }
            }
            if store.isOptimizing {
                HStack { ProgressView(); Button("요청 중단", action: store.cancel) }
            } else {
                Button("티맵으로 배송 순서 최적화 · 1회 사용") {
                    inputs.finishEditing(); store.optimize(plan: planner.plan)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canRequest || store.quota(for: planner.plan.visits.count) == nil || store.quota(for: planner.plan.visits.count)?.blocked == true || planner.isComputing)
            }
            Text(store.message).font(.caption).foregroundColor(.secondary)
            if !store.hasAppKey || !store.freePlanConfirmed { Button("Free 앱키 설정") { showSettings = true } }
            if planner.plan.tmapBinding != nil {
                Button("계획에 연결한 티맵 순서 해제") { inputs.finishEditing(); planner.releaseTMapOrder() }
                    .disabled(planner.isComputing || store.isOptimizing)
            }
            Text("시간·점심 회피·적재 조건은 결과 반영 시 다시 검증합니다. 하역 방향과 실제 통행 가능 여부는 등록한 도로 조건으로 확인합니다.").font(.caption)
        }
    }
    private var timingSection: some View {
        Section("티맵에 전달할 시간") {
            switch timingPreview {
            case .success(let timing):
                Text("출발 예정 \(requestTime(timing.startTime))")
                ForEach(timing.stops) { stop in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stop.name).bold()
                        Text(stop.windowCount == 0 ? "도착 시간대 제한 없음" : "희망 도착 \(requestTime(stop.wishStartTime)) ~ \(requestTime(stop.wishEndTime))")
                            .font(.caption)
                        Text("배송·매입 작업 \(stop.viaTime / 60)분").font(.caption)
                    }
                }
                ForEach(Array(timing.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.caption).foregroundColor(.orange)
                }
            case .failure(let error):
                Text(error.localizedDescription).font(.caption).foregroundColor(.red)
            }
            Text("출발시각과 거래처 시간 조건은 배송계획에서 입력·수정합니다. 위 시간은 티맵에 도착 희망 시간대로 전달하며, 실제 작업시작·점심 회피·대기·휴식은 결과 반영 후 다시 검증합니다.").font(.caption).foregroundColor(.secondary)
        }
    }
    private var timingPreview: Result<TMapTimeInputs, Error> {
        do {
            return .success(try TMapBridge.timeInputs(planner.plan))
        } catch { return .failure(error) }
    }
    private func requestTime(_ text: String) -> String {
        guard text.count == 12, text.allSatisfy(\.isNumber) else { return "시각 미지정" }
        let chars = Array(text)
        return String(chars[4...5]) + "/" + String(chars[6...7]) + " " + String(chars[8...9]) + ":" + String(chars[10...11])
    }
    private var quotaSection: some View {
        Section("무료 잔여량 · 이 기기 호출 기준") {
            if store.quotas.isEmpty { Text("앱키를 등록하고 기준 시각을 확인하면 표시됩니다.").font(.caption) }
            ForEach(store.quotas) { quota in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(quota.id)곳용")
                        Spacer()
                        Text(quota.serverBlocked ? "서버 차단" : "\(quota.remaining)/\(quota.limit)회 남음")
                            .foregroundColor(quota.blocked ? .orange : .primary)
                    }
                    ProgressView(value: Double(quota.remaining), total: Double(quota.limit))
                    Text("기록한 요청 \(quota.used)회 · 다음 초기화 \(resetTime(quota.resetAtMillis))").font(.caption2).foregroundColor(.secondary)
                    Button("다른 곳에서 사용한 횟수 반영") {
                        usageDraft = quota.id; usageText = String(quota.used); showUsage = true
                    }.font(.caption)
                }.padding(.vertical, 4)
            }
            Button(store.isRefreshing ? "기준 시각 확인 중…" : "잔여량·기준 시각 새로 확인") { Task { await store.refreshClock() } }
                .disabled(store.isRefreshing || store.isOptimizing)
            Text("실패·중단한 요청도 포함합니다. 같은 키를 다른 기기나 테스트에서 사용했다면 총 사용 횟수를 반영해 주세요. 실제 서버 잔여량을 직접 조회하는 기능은 없습니다.").font(.caption)
            Text("앱의 일 한도는 한국시간 자정을 기준으로 계산하고, 5분 뒤 재개합니다. 티맵 서버가 계속 제한하면 다시 차단합니다. 초기화 시각은 공식 확인 전의 앱 설정 기준입니다.").font(.caption).foregroundColor(.secondary)
        }
    }
    @ViewBuilder
    private func routeSection(_ route: TMapRoute) -> some View {
        Section("티맵 제안 경로") {
            routeSummary(route)
            Text("티맵의 예상 일정입니다. 작업 시작은 응답의 도착·대기 또는 완료·작업시간으로 계산합니다. 앱의 휴식·재배치·최종 배송 조건 검증 후 일정이 달라질 수 있습니다.").font(.caption)
            ForEach(Array(route.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.caption).foregroundColor(.orange)
            }
            TMapRouteMap(route: route, plan: planner.plan).frame(height: 280)
            Text("받은 시각 \(resetTime(route.fetchedAtMillis)) · 유효기간 \(resetTime(route.expiresAtMillis))까지").font(.caption2)
            Button("티맵 순서를 배송계획에 반영하고 검증") {
                inputs.finishEditing(); store.apply(to: planner)
            }.buttonStyle(.borderedProminent)
                .disabled(!store.canApply(to: planner.plan) || planner.isComputing || store.isOptimizing)
            if !store.canApply(to: planner.plan) { Text("이미 반영했거나 입력이 달라졌습니다. 현재 계획의 새 순서가 필요하면 다시 요청하세요.").font(.caption) }
            ForEach(route.rows) { row in routeRow(row) }
        }
    }
    @ViewBuilder
    private func routeSummary(_ route: TMapRoute) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(route.totalDistanceMeters / 1000, specifier: "%.1f")km · 구간 이동 \(duration(route.totalTravelSeconds))").font(.headline)
            Text("요청 출발 \(arrivalTime(route.requestedDepartureTime)) · 티맵 회사 복귀 \(arrivalTime(route.returnTime))").font(.caption)
            if !route.reportedDepartureTime.isEmpty, route.reportedDepartureTime != route.requestedDepartureTime {
                Text("티맵 응답 출발 \(arrivalTime(route.reportedDepartureTime)) · 출발~복귀는 이 시각 기준입니다.").font(.caption).foregroundColor(.orange)
            }
            Text("티맵 출발~복귀 \(duration(route.elapsedSeconds)) · 작업 \(duration(route.totalDeliverySeconds)) · 대기 \(duration(route.totalWaitSeconds))").font(.caption)
            Text("총 통행료 \(toll(route.totalTollWon))").bold()
            if route.unknownTollCount > 0 {
                Text("구간 통행료 미제공 \(route.unknownTollCount)개 · 확인된 구간 합계 \(toll(route.knownTollWon))").font(.caption)
            }
            if let reported = route.providerTotalTravelSeconds {
                Text("티맵 총 경로 소요시간 \(duration(reported)) · API 총 시간에는 체류시간이 포함되지 않습니다.").font(.caption2).foregroundColor(.secondary)
            }
            if let reported = route.providerTotalDistanceMeters, abs(reported - route.totalDistanceMeters) > Double(route.rows.count) {
                Text("티맵 응답 총 거리 \(reported / 1000, specifier: "%.1f")km · 구간 합계와 달라 확인이 필요합니다.").font(.caption).foregroundColor(.orange)
            }
            if let reported = route.providerTotalTollWon, route.totalTollWon == nil {
                Text("티맵 응답 총액 \(toll(reported)) · 구간 합계 \(toll(route.knownTollWon)) · 확인 필요").font(.caption).foregroundColor(.orange)
            }
        }
    }
    @ViewBuilder
    private func routeRow(_ row: TMapRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.visitID == "depot" ? "회사 복귀" : "\(row.position). \(planner.plan.name(row.visitID))").bold()
            Text("이동 \(duration(row.travelSeconds)) · \(row.distanceMeters / 1000, specifier: "%.1f")km · 통행료 \(toll(row.tollWon))").font(.caption)
            Text("티맵 도착 \(arrivalTime(row.arriveTime))").font(.caption)
            if row.visitID != "depot" {
                Text("예상 작업 시작 \(arrivalTime(row.workStartTime)) · 완료 \(arrivalTime(row.completeTime))").font(.caption)
                Text("작업 \(duration(row.deliverySeconds)) · 대기 \(duration(row.waitSeconds))").font(.caption)
                if !row.detailAddress.isEmpty { Text(row.detailAddress).font(.caption) }
            }
            if !row.scheduleIssues.isEmpty { Text("등록 시간 조건과 응답 일정 확인 필요").font(.caption).foregroundColor(.orange) }
            if !row.poiID.isEmpty {
                DisclosureGroup("티맵 안내 장소 확인") { Text("장소 ID: \(row.poiID)").font(.caption2) }
            }
        }
    }
    private func duration(_ seconds: Int?) -> String {
        guard let seconds = seconds else { return "미제공" }
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, remainder = seconds % 60
        return (hours > 0 ? "\(hours)시간 " : "") + "\(minutes)분" + (remainder > 0 ? " \(remainder)초" : "")
    }
    private func toll(_ value: Double?) -> String {
        guard let value = value else { return "미확인" }
        return String(format: "%.0f원", value)
    }
    private var locationsSection: some View {
        Section("하역 위치 좌표") {
            Button("네이버 검색에서 장소·주소 가져오기") { inputs.finishEditing(); openNaver("https://map.naver.com/p/") }
                .disabled(store.isOptimizing)
            Button("네이버에 저장한 거래처 목록 열기") { inputs.finishEditing(); openNaver("https://map.naver.com/p/favorite") }
                .disabled(store.isOptimizing)
            Text("네이버에서 장소를 선택하고 ‘선택 장소 읽기’를 누르면 새 거래처 등록과 기존 거래처 연결을 할 수 있습니다.").font(.caption)
            ForEach(planner.plan.nodes, id: \.id) { node in
                Button {
                    inputs.finishEditing()
                    locationDraft = TMapLocationDraft(id: node.id, name: node.name, coordinate: TMapBridge.coordinate(planner.plan, id: node.id))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name).foregroundColor(.primary)
                        if let place = planner.plan.naverPlace(node.id), !place.preferredAddress.isEmpty {
                            Text("네이버: \(place.preferredAddress)").font(.caption).foregroundColor(.secondary)
                        }
                        if let coordinate = TMapBridge.coordinate(planner.plan, id: node.id) {
                            Text("경도 \(coordinate.longitude, specifier: "%.6f") · 위도 \(coordinate.latitude, specifier: "%.6f")").font(.caption).foregroundColor(.secondary)
                            if let address = coordinate.detailAddress, !address.isEmpty { Text(address).font(.caption).foregroundColor(.secondary) }
                        } else { Text("좌표 입력 필요").font(.caption).foregroundColor(.orange) }
                    }
                }.disabled(store.isOptimizing)
            }
            Text("확인한 네이버 하역 지점이 있으면 그 좌표를 사용합니다. 별도로 입력할 때도 차량이 서는 실제 지점을 지정하세요.").font(.caption)
        }
    }
    private var usageEditor: some View {
        NavigationStack {
            Form {
                Section("대시보드의 오늘 총 사용 횟수") {
                    NativeTextField("사용 횟수", text: $usageText, keyboard: .numberPad, digitsOnly: true).frame(minHeight: 44)
                    Text("\(usageDraft ?? 0)곳용 API의 사용 횟수를 늘리는 보정만 가능합니다. 기존 기록·서버 차단은 초기화 전까지 줄이거나 해제하지 않습니다.").font(.caption)
                    Link("SK open API 대시보드", destination: URL(string: "https://openapi.sk.com/")!)
                }
                Button("사용 횟수 반영") {
                    inputs.finishEditing()
                    guard let id = usageDraft, let used = Int(usageText) else { return }
                    store.raiseUsed(apiID: id, used: used); showUsage = false
                }
            }.navigationTitle("사용량 맞추기")
        }
    }
    private func resetTime(_ millis: Double) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "ko_KR")
        format.timeZone = TimeZone(identifier: "Asia/Seoul")
        format.dateFormat = "M/d HH:mm"
        return format.string(from: Date(timeIntervalSince1970: millis / 1000))
    }
    private func arrivalTime(_ text: String) -> String {
        guard text.count == 14, text.allSatisfy(\.isNumber) else { return "시각 미제공" }
        let chars = Array(text)
        return String(chars[4...5]) + "/" + String(chars[6...7]) + " " + String(chars[8...9]) + ":" + String(chars[10...11]) + ":" + String(chars[12...13])
    }
}

private struct TMapRouteMap: View {
    let route: TMapRoute
    let plan: DeliveryPlan
    var body: some View {
        Map {
            ForEach(route.paths) { path in
                MapPolyline(coordinates: path.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(.blue, lineWidth: 4)
            }
            ForEach(route.rows) { row in
                if let coordinate = row.coordinate ?? TMapBridge.coordinate(plan, id: row.visitID) {
                    Marker(row.visitID == "depot" ? "회사" : "\(row.position). \(plan.name(row.visitID))", coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
            }
        }.mapControls { MapCompass(); MapScaleView() }
    }
}

struct TMapLegMap: View {
    let provider: TMapProviderLeg
    var body: some View {
        Map {
            MapPolyline(coordinates: provider.geometry.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }).stroke(.blue, lineWidth: 4)
            Marker("출발 하역 지점", coordinate: CLLocationCoordinate2D(latitude: provider.requestFrom.latitude, longitude: provider.requestFrom.longitude))
            Marker("도착 하역 지점", coordinate: CLLocationCoordinate2D(latitude: provider.requestTo.latitude, longitude: provider.requestTo.longitude))
        }
    }
}

private struct TMapSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inputs: NativeInputSession
    @ObservedObject var store: TMapStore
    @State private var appKey = ""
    @State private var freeConfirmed = false
    @State private var options = TMapOptions()
    var body: some View {
        NavigationStack {
            Form {
                Section("무료 상품과 앱키") {
                    SecureField(store.hasAppKey ? "키 변경 시에만 입력" : "발급받은 appKey", text: $appKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("SK open API의 Free 상품임을 확인함", isOn: $freeConfirmed)
                    Text("Free 상품은 서버에서도 한도 초과를 차단합니다. 유료 종량제로 바꾸지 않고 사용하세요. 앱키와 사용량은 같은 기기에서 유지됩니다.").font(.caption)
                    Link("앱키 발급·상품 확인", destination: URL(string: "https://openapi.sk.com/")!)
                }
                Section("경로 기준") {
                    Picker("탐색 기준", selection: $options.searchOption) {
                        Text("최소시간").tag("2")
                        Text("추천").tag("0")
                        Text("무료도로 우선").tag("1")
                        Text("초보운전").tag("3")
                        Text("최단거리").tag("10")
                    }
                    Picker("경로 안내정보 활용", selection: $options.deliveryAccuracy) {
                        Text("최대한 활용").tag("1")
                        Text("보통 활용").tag("2")
                        Text("최소 활용").tag("3")
                    }
                    Text("배송 결과 정확도 설정입니다. 기본은 안내정보를 최대한 활용합니다. 초보운전 옵션도 실제 하역 방향과 통과 높이를 따로 확인해야 합니다.").font(.caption)
                    Text("포터의 통행료는 1종 기준으로 요청합니다.").font(.caption)
                }
                Section("화물차 제한 고려") {
                    Toggle("차량 치수·중량을 요청에 반영", isOn: $options.truckRouting)
                    if options.truckRouting {
                        NumberRow(title: "전체 폭(cm)", value: $options.truckWidth)
                        NumberRow(title: "화물 포함 전체 높이(cm)", value: $options.truckHeight)
                        NumberRow(title: "전체 길이(cm)", value: $options.truckLength)
                        NumberRow(title: "적재중량(kg)", value: $options.truckWeight)
                        NumberRow(title: "총중량(kg)", value: $options.truckTotalWeight)
                        Text("티맵 요청 규격에 맞춰 실제 차량 치수와 중량을 입력합니다. 미입력 시 API를 호출하지 않습니다.").font(.caption)
                    }
                }
                if let error = store.errorMessage { Text(error).foregroundColor(.red).font(.caption) }
            }
            .navigationTitle("티맵 설정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { inputs.finishEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") {
                    inputs.finishEditing(); store.saveSettings(appKey: appKey, freeConfirmed: freeConfirmed, options: options)
                    if store.errorMessage == nil { dismiss() }
                } }
            }
            .onAppear { freeConfirmed = store.freePlanConfirmed; options = store.options }
        }
    }
}

private struct TMapLocationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inputs: NativeInputSession
    let name: String
    let coordinate: TMapCoordinate?
    let isDepot: Bool
    let save: (TMapCoordinate) -> Void
    @State private var longitude = ""
    @State private var latitude = ""
    @State private var poiID = ""
    @State private var detailAddress = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(name).bold()
                NativeTextField("경도 · 예: 127.123456", text: $longitude, keyboard: .decimalPad).frame(minHeight: 44)
                NativeTextField("위도 · 예: 36.123456", text: $latitude, keyboard: .decimalPad).frame(minHeight: 44)
                Text("WGS84 경위도 좌표입니다. 실제 하역 위치를 확인한 값을 입력하세요.").font(.caption)
                if !isDepot {
                    NativeTextField("상세주소 · 예: 급식실 출입구", text: $detailAddress).frame(minHeight: 44)
                }
                DisclosureGroup("티맵 장소 ID · 알고 있는 경우") {
                    NativeTextField("티맵 검색 결과의 장소 ID", text: $poiID).frame(minHeight: 44)
                    Text("선택 입력입니다. 티맵 검색 결과의 ID와 현재 하역 좌표가 같은 장소인지 확인하세요. 네이버 장소 ID는 사용할 수 없습니다. 회사 ID는 회사 복귀 목적지에도 전달합니다.").font(.caption)
                }
                if let error = error { Text(error).foregroundColor(.red) }
            }.navigationTitle("하역 위치")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { inputs.finishEditing(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("저장") {
                        inputs.finishEditing()
                        guard let lon = Double(longitude), let lat = Double(latitude), lon.isFinite, lat.isFinite, (124...132).contains(lon), (32...40).contains(lat) else { error = "경도 124~132, 위도 32~40 범위인지 확인해 주세요."; return }
                        let pointID = poiID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let address = detailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard pointID.utf16.count <= 128, pointID.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) == nil, address.utf16.count <= 1000, address.rangeOfCharacter(from: .controlCharacters) == nil else { error = "장소 ID는 공백 없이 128자 이하, 상세주소는 한 줄로 1000자 이하인지 확인해 주세요."; return }
                        save(TMapCoordinate(longitude: lon, latitude: lat, poiID: pointID.isEmpty ? nil : pointID, detailAddress: address.isEmpty ? nil : address)); dismiss()
                    } }
                }
                .onAppear {
                    if let coordinate = coordinate { longitude = String(coordinate.longitude); latitude = String(coordinate.latitude); poiID = coordinate.poiID ?? ""; detailAddress = coordinate.detailAddress ?? "" }
                }
        }
    }
}
