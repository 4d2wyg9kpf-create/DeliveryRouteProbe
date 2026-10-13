import SwiftUI
import UniformTypeIdentifiers

extension EvaluationSite {
    init(_ site: SiteTarget) {
        self.init(id: SiteTargetStore.sharingKey(site), name: site.name, address: site.address,
                  longitude: site.effectiveCoordinate.longitude, latitude: site.effectiveCoordinate.latitude)
    }
}
private func evaluationNumber(_ value: Double) -> String { String(format: "%.6g", value) }
private func evaluationTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date) + " 한국시간"
}

struct EvaluationReferenceView: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @State private var editingCriterion: EvaluationCriterion?
    @State private var editingConditions = false
    @State private var title = ""
    @State private var preview: EvaluationReference?
    @State private var error: String?
    var body: some View {
        List {
            Section("확정 평가 기준") {
                if let reference = store.active {
                    NavigationLink { EvaluationReferenceDetailView(reference: reference, confirming: false) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reference.title).bold()
                            Text("표준 대상 \(reference.standards.count)곳 · 항목 \(reference.distributions.count)개").font(.caption)
                            Text("확정 " + evaluationTimestamp(reference.createdAt)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink("이 기준으로 대상별 점수 조회") { EvaluationScoresView() }
                    if store.needsReferenceUpdate(sites: sites.records.map(EvaluationSite.init)) {
                        Text("표준 대상·원자료·평가 조건 변경됨 · 기준 갱신 필요").font(.caption).foregroundStyle(.orange)
                        Button("기준 갱신·전체 평가지 점수 재계산") {
                            perform { preview = try store.preview(title: reference.title + " · 갱신", sites: sites.records.map(EvaluationSite.init)) }
                        }.buttonStyle(.borderedProminent)
                        Text("변경 사항을 확인하고 새 기준을 확정하면 모든 평가지에 새 기준을 적용합니다. 같은 조회 조건과 항목의 원자료는 다시 수집하지 않고 재사용합니다.").font(.caption).foregroundStyle(.secondary)
                    }
                } else { Text("표준 대상과 원자료를 확인하고 기준을 확정하세요.").foregroundStyle(.secondary) }
                Text("새 평가지 추가 시에는 기준을 유지합니다. 표준 대상 변경을 반영할 때는 기준분포를 갱신하고 전체 점수를 재계산합니다. 점수에는 적용한 기준 버전을 표시합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("새 기준 준비") {
                NavigationLink("표준 대상 선택 · \(store.standardCount)곳") { EvaluationStandardPicker() }
                NavigationLink("대상별 원자료 입력·확인") {
                    EvaluationObservationList(criteria: store.archive.configuration.criteria, conditions: store.archive.configuration.conditions)
                }
                Button("평가 시각·조회 조건 설정") { editingConditions = true }
                Text(evaluationTimestamp(store.archive.configuration.conditions.departure)).font(.caption)
                Text("표준 대상은 지역·도시/농촌·주택 유형·입지 수준을 고르게 포함하도록 선정하세요. 현재는 확인한 원자료를 직접 입력하며, 전체 평가 항목의 자동 수집은 별도로 구현해야 합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("평가 항목 · \(store.archive.configuration.criteria.count)개") {
                ForEach(store.archive.configuration.criteria) { criterion in
                    Button { editingCriterion = criterion } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(criterion.title)
                            Text("\(criterion.major) / \(criterion.middle) · \(criterion.unit) · \(criterion.direction.title)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { offsets in
                    let ids = offsets.map { store.archive.configuration.criteria[$0].id }
                    perform { for id in ids { try store.removeCriterion(id) } }
                }
                Button("평가 항목 추가") { editingCriterion = EvaluationCriterion(title: "", major: "", middle: "", unit: "") }
                Text("각 항목을 정규화한 뒤 중분류 안에서 평균, 대분류 안에서 평균, 대분류 점수의 평균을 총점으로 사용합니다. 시설 수는 클수록, 소요시간·불이익 순위는 작을수록 우수로 설정합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("기준분포 확인·확정") {
                NativeTextField("기준 이름 (예: 2026년 전국 기준 1)", text: $title).frame(minHeight: 44)
                Button("선택한 표준 대상으로 기준 미리보기") {
                    perform { preview = try store.preview(title: title, sites: sites.records.map(EvaluationSite.init)) }
                }.buttonStyle(.borderedProminent)
                Text("선택한 표준 대상 모두에 현재 좌표·단위·조회 조건에 맞는 원자료가 필요합니다. 항목별 평균·표준편차와 표본을 확인한 후 확정합니다.").font(.caption).foregroundStyle(.secondary)
                if let error = error ?? store.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            }
            if !store.archive.references.isEmpty {
                Section("기준 버전 기록") {
                    ForEach(store.archive.references.reversed()) { reference in
                        NavigationLink(reference.title + (reference.id == store.active?.id ? " · 적용 중" : "")) {
                            EvaluationReferenceDetailView(reference: reference, confirming: false)
                        }
                    }
                }
            }
        }.navigationTitle("표준 대상·평가 기준").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingCriterion) { EvaluationCriterionEditor(criterion: $0) }
            .sheet(isPresented: $editingConditions) { EvaluationConditionsEditor(conditions: store.archive.configuration.conditions) }
            .sheet(item: $preview) { reference in NavigationStack { EvaluationReferenceDetailView(reference: reference, confirming: true) } }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
}

private struct EvaluationStandardPicker: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @State private var keyword = ""
    @State private var standardsOnly = false
    @State private var error: String?
    private var available: [EvaluationSite] { sites.records.map(EvaluationSite.init) }
    private var filtered: [EvaluationSite] {
        available.filter { (!standardsOnly || store.archive.sites[$0.id]?.standardWeight != nil) &&
            (keyword.isEmpty || ($0.name + " " + $0.address).localizedCaseInsensitiveContains(keyword)) }
    }
    private var missing: [EvaluationSiteRecord] {
        let ids = Set(available.map(\.id))
        return store.archive.sites.values.filter { $0.standardWeight != nil && !ids.contains($0.site.id) }.sorted { $0.site.name < $1.site.name }
    }
    var body: some View {
        List {
            Section {
                NativeTextField("대상지 이름·주소 찾기", text: $keyword).frame(minHeight: 44)
                Toggle("선택한 표준 대상만 보기", isOn: $standardsOnly)
                Text("표준 대상 \(store.standardCount)곳 · 모든 평가대상지 중 일부만 선택합니다.").font(.caption)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            ForEach(filtered) { site in
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        do { try store.setStandard(site, weight: store.archive.sites[site.id]?.standardWeight == nil ? 1 : nil); error = nil }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        Label(site.name, systemImage: store.archive.sites[site.id]?.standardWeight == nil ? "circle" : "checkmark.circle.fill")
                    }
                    Text(site.address).font(.caption).foregroundStyle(.secondary)
                    if let weight = store.archive.sites[site.id]?.standardWeight {
                        NavigationLink("표본 가중치 \(evaluationNumber(weight))") { EvaluationWeightEditor(site: site, initial: weight) }
                            .font(.caption)
                    }
                }
            }
            if !missing.isEmpty {
                Section("평가대상지 목록에서 삭제된 표준 대상") {
                    ForEach(missing, id: \.site.id) { record in
                        Button("\(record.site.name) · 표준 선택 해제") {
                            do { try store.removeMissingStandard(record.site.id) } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }.navigationTitle("표준 대상 선택").navigationBarTitleDisplayMode(.inline)
    }
}

private struct EvaluationWeightEditor: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    let site: EvaluationSite
    @State private var weight: String
    @State private var error: String?
    init(site: EvaluationSite, initial: Double) { self.site = site; _weight = State(initialValue: String(initial)) }
    var body: some View {
        Form {
            Text(site.name).bold()
            NativeTextField("표본 가중치", text: $weight, keyboard: .decimalPad).frame(minHeight: 44)
            Text("기본은 1입니다. 특정 지역·유형을 실제 비율보다 많이 뽑았다면 표본의 대표 비율을 보정합니다. 항목·중분류·대분류의 동일 비중 평균과는 별개입니다.").font(.caption).foregroundStyle(.secondary)
            Button("저장") {
                do {
                    inputs.finishEditing()
                    guard let value = Double(weight.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw EvaluationFailure.message("양수 가중치를 입력하세요.") }
                    try store.setStandard(site, weight: value); dismiss()
                } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("표본 가중치")
    }
}

private struct EvaluationCriterionEditor: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State var criterion: EvaluationCriterion
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("항목 정의") {
                    field("항목명", $criterion.title); field("대분류", $criterion.major)
                    field("중분류", $criterion.middle); field("원자료 단위 (초·개·순위 등)", $criterion.unit)
                    Picker("점수 방향", selection: $criterion.direction) { ForEach(EvaluationDirection.allCases) { Text($0.title).tag($0) } }
                }
                Text("시간은 초 또는 분 등 한 단위로 통일하세요. 순서형 지표는 정해 둔 순위 수치를 입력하고 동점은 같은 수치를 사용합니다. 정의를 바꾸면 새 원자료가 필요하며 확정 기준은 유지됩니다.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("평가 항목").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") {
                    do {
                        inputs.finishEditing()
                        criterion.title = criterion.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        criterion.major = criterion.major.trimmingCharacters(in: .whitespacesAndNewlines)
                        criterion.middle = criterion.middle.trimmingCharacters(in: .whitespacesAndNewlines)
                        criterion.unit = criterion.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                        try store.saveCriterion(criterion); dismiss()
                    } catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
    private func field(_ title: String, _ binding: Binding<String>) -> some View { NativeTextField(title, text: binding).frame(minHeight: 44) }
}

private struct EvaluationConditionsEditor: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State var conditions: EvaluationConditions
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("자동차 출발 기준", selection: $conditions.departure)
                    .environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!)
                NativeTextField("조회 조건·시설 후보군·반경·경로 기준", text: $conditions.description).frame(minHeight: 44)
                Text("표준 대상과 평가대상지에 동일한 조건을 사용합니다. 조건을 변경하면 이전 조건의 원자료를 새 기준에 섞지 않습니다. 이 설정이 길찾기 화면의 조회 시각을 자동 변경하지는 않습니다.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("평가 조건").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") {
                    do { inputs.finishEditing(); try store.saveConditions(departure: conditions.departure, description: conditions.description); dismiss() }
                    catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
}

private struct EvaluationObservationList: View {
    @EnvironmentObject private var sites: SiteTargetStore
    let criteria: [EvaluationCriterion]
    let conditions: EvaluationConditions
    @State private var keyword = ""
    var body: some View {
        List {
            NativeTextField("대상지 이름·주소 찾기", text: $keyword).frame(minHeight: 44)
            if criteria.isEmpty { Text("평가 항목을 먼저 추가하세요.").foregroundStyle(.secondary) }
            ForEach(sites.records.filter { keyword.isEmpty || ($0.name + " " + $0.address).localizedCaseInsensitiveContains(keyword) }) { site in
                NavigationLink(site.name) { EvaluationObservationEditor(siteID: site.id, criteria: criteria, conditions: conditions) }
                    .disabled(criteria.isEmpty)
            }
        }.navigationTitle("원자료 입력·확인").navigationBarTitleDisplayMode(.inline)
    }
}

private struct EvaluationObservationEditor: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    let siteID: String
    let criteria: [EvaluationCriterion]
    let conditions: EvaluationConditions
    @State private var values: [String: String] = [:]
    @State private var source = ""
    @State private var loadedSite: EvaluationSite?
    @State private var error: String?
    private var current: EvaluationSite? { sites.records.first { $0.id == siteID }.map(EvaluationSite.init) }
    var body: some View {
        Form {
            if let current {
                Section {
                    Text(current.name).bold(); Text(current.address).font(.caption)
                    Text(evaluationTimestamp(conditions.departure)).font(.caption)
                    Text(conditions.description).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(criteria) { criterion in
                    Section(criterion.title + " · " + criterion.unit) {
                        NativeTextField("확인한 원자료 · 빈칸은 미확인", text: Binding(get: { values[criterion.id] ?? "" }, set: { values[criterion.id] = $0 }), keyboard: .decimalPad).frame(minHeight: 44)
                        Text("\(criterion.major) / \(criterion.middle) · \(criterion.direction.title)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("원자료 출처·메모") { NativeTextField("제공자·조회 기준·확인 시각 등", text: $source).frame(minHeight: 44) }
                Text("현재는 원자료 직접 입력 방식입니다. 누락·조회 실패는 빈칸으로 두고, 실제로 확인된 0만 0으로 입력하세요.").font(.caption).foregroundStyle(.secondary)
                Button("원자료 저장") { save(current) }.buttonStyle(.borderedProminent)
            } else { Text("평가대상지가 삭제되었습니다.").foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.navigationTitle("대상지 원자료").navigationBarTitleDisplayMode(.inline).onAppear {
            guard loadedSite == nil, let current else { return }; loadedSite = current
            let record = store.archive.sites[current.id]
            for criterion in criteria {
                if let value = record?.value(criterion, conditions: conditions, site: current) { values[criterion.id] = String(value) }
            }
            if let criterion = criteria.first { source = record?.observations[conditions.id + "/" + criterion.revision]?.source ?? "" }
        }
    }
    private func save(_ site: EvaluationSite) {
        do {
            inputs.finishEditing()
            guard loadedSite?.longitude == site.longitude, loadedSite?.latitude == site.latitude else { throw EvaluationFailure.message("좌표가 변경되었습니다. 화면을 다시 열고 새 좌표의 원자료를 확인하세요.") }
            var parsed: [String: Double] = [:]
            for criterion in criteria {
                let text = (values[criterion.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    guard let value = Double(text), value.isFinite, value >= 0 else { throw EvaluationFailure.message("\(criterion.title): 0 이상인 수치를 입력하세요.") }
                    parsed[criterion.id] = value
                }
            }
            try store.saveObservations(site: site, criteria: criteria, conditions: conditions, values: parsed, source: source); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct EvaluationReferenceDetailView: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @Environment(\.dismiss) private var dismiss
    let reference: EvaluationReference
    let confirming: Bool
    @State private var error: String?
    @State private var exporting = false
    @State private var document = DataTextDocument()
    var body: some View {
        List {
            Section(confirming ? "확정 전 미리보기" : "확정 기준") {
                Text(reference.title).bold()
                Text("버전 ID " + reference.id).font(.caption).textSelection(.enabled)
                Text("표준 대상 \(reference.standards.count)곳 · 항목 \(reference.distributions.count)개")
                Text("자동차 출발 " + evaluationTimestamp(reference.conditions.departure)).font(.caption)
                Text(reference.conditions.description).font(.caption).foregroundStyle(.secondary)
                Text("정규분포를 가정한 0~1 점수입니다. 표본을 Z점수로 바꿔도 실제 분포가 정규분포가 되는 것은 아니며, 이 점수는 전국 실제 백분위로 확정되는 값은 아닙니다.").font(.caption).foregroundStyle(.secondary)
                if confirming {
                    Button("새 기준 확정·전체 평가지 점수 재계산") {
                        do { try store.confirm(reference); dismiss() } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                } else if store.active?.id != reference.id {
                    Button("이 기준 버전으로 점수 조회") { do { try store.activate(reference.id) } catch { self.error = error.localizedDescription } }
                }
                Button("표준 대상·원자료·기준분포 JSON 내보내기") {
                    do { document = DataTextDocument(String(decoding: try DeviceShareCodec.encode(reference), as: UTF8.self)); exporting = true }
                    catch { self.error = error.localizedDescription }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("항목별 고정 기준분포") {
                ForEach(reference.distributions, id: \.criterion.id) { distribution in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(distribution.criterion.title).bold()
                        Text("\(distribution.criterion.major) / \(distribution.criterion.middle) · \(distribution.criterion.direction.title)").font(.caption)
                        Text("평균 \(evaluationNumber(distribution.mean)) · 표준편차 \(evaluationNumber(distribution.standardDeviation)) \(distribution.criterion.unit)")
                        Text("표본 \(distribution.count) · 가중치 기준 유효 표본수 \(evaluationNumber(distribution.effectiveCount))").font(.caption)
                        Text("원자료 범위 \(evaluationNumber(distribution.minimum))~\(evaluationNumber(distribution.maximum))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("이 버전에 고정한 표준 대상") {
                ForEach(reference.standards, id: \.site.id) { standard in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(standard.site.name)
                        Text(standard.site.address).font(.caption).foregroundStyle(.secondary)
                        Text("표본 가중치 " + evaluationNumber(standard.weight)).font(.caption)
                    }
                }
            }
        }.navigationTitle(confirming ? "기준 확인" : reference.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { if confirming { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } } }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "평가기준-" + reference.id) { result in if case .failure(let failure) = result { error = failure.localizedDescription } }
    }
}

private struct EvaluationScoresView: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @State private var keyword = ""
    var body: some View {
        Group {
          if let reference = store.active {
           List {
            Section("적용 기준") {
                Text(reference.title).bold(); Text("버전 ID " + reference.id).font(.caption).textSelection(.enabled)
                if store.needsReferenceUpdate(sites: sites.records.map(EvaluationSite.init)) {
                    Text("기준 변경 준비 중 · 현재 점수는 표시된 확정 기준으로 계산합니다. 새 기준 확정 시 전체 점수가 갱신됩니다.").font(.caption).foregroundStyle(.orange)
                }
                NativeTextField("대상지 이름·주소 찾기", text: $keyword).frame(minHeight: 44)
            }
            ForEach(sites.records.filter { keyword.isEmpty || ($0.name + " " + $0.address).localizedCaseInsensitiveContains(keyword) }) { site in
                NavigationLink { EvaluationScoreDetailView(siteID: site.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(site.name).bold()
                        if let result = try? store.currentResult(site: EvaluationSite(site)), let total = result.total {
                            Text("총점 \(total, specifier: "%.4f")").monospacedDigit()
                        } else { Text("원자료 확인 필요 · 총점 보류").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
           }
          } else { Text("평가 기준을 먼저 확정하세요.") }
        }.navigationTitle("고정 기준 점수").navigationBarTitleDisplayMode(.inline)
    }
}

private struct EvaluationScoreDetailView: View {
    @EnvironmentObject private var store: EvaluationReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    let siteID: String
    private var current: EvaluationSite? { sites.records.first { $0.id == siteID }.map(EvaluationSite.init) }
    var body: some View {
        Group {
          if let reference = store.active {
           List {
            Section {
                Text(current?.name ?? "삭제된 평가대상지").bold()
                Text("기준 " + reference.title).font(.caption)
                Text("버전 ID " + reference.id).font(.caption).textSelection(.enabled)
                NavigationLink("이 기준의 원자료 입력·수정") { EvaluationObservationEditor(siteID: siteID, criteria: reference.criteria, conditions: reference.conditions) }
                    .disabled(current == nil)
            }
            if let current, let result = try? store.currentResult(site: current) {
                Section("평가 점수") {
                    if let total = result.total { Text("총점 \(total, specifier: "%.4f")").bold().monospacedDigit() }
                    else { Text("총점 보류 · 미확인 항목: " + result.missing.joined(separator: ", ")).foregroundStyle(.orange) }
                    ForEach(reference.criteria) { criterion in
                        if let value = result.scores[criterion.id] { LabeledContent(criterion.title, value: String(format: "%.4f", value)) }
                        else { LabeledContent(criterion.title, value: "미확인") }
                    }
                }
                if result.total != nil {
                    Section("중분류 동일 비중 평균") { ForEach(result.middleScores.keys.sorted(), id: \.self) { key in LabeledContent(key, value: String(format: "%.4f", result.middleScores[key]!)) } }
                    Section("대분류 동일 비중 평균") { ForEach(result.majorScores.keys.sorted(), id: \.self) { key in LabeledContent(key, value: String(format: "%.4f", result.majorScores[key]!)) } }
                }
            }
           }
          } else { Text("평가 기준을 먼저 확정하세요.") }
        }.navigationTitle("대상지 점수").navigationBarTitleDisplayMode(.inline)
    }
}
