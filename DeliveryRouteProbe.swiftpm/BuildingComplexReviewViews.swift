import SwiftUI

struct BuildingComplexReviewView: View {
    @EnvironmentObject private var references: BuildingReferenceStore
    @EnvironmentObject private var sites: SiteTargetStore
    @EnvironmentObject private var inputs: NativeInputSession
    @Environment(\.dismiss) private var dismiss
    @State private var review: BuildingComplexReview
    @State private var message: String?
    let onSaved: (BuildingComplexReview) -> Void
    init(review: BuildingComplexReview, onSaved: @escaping (BuildingComplexReview) -> Void) {
        _review = State(initialValue:review); self.onSaved = onSaved
    }
    private var groupOptions: [BuildingComplexSource] { review.candidates.filter { review.roots.contains($0.id) } }
    var body: some View {
        NavigationStack {
            Form {
                Section("이 주소와 연결된 K-apt 등록 비교") {
                    Text(review.roadAddress)
                    Text("같은 주소·지번은 비교 후보입니다. 중복 등록은 같은 관리단지로 묶고 전체 범위의 원본 하나를 채택합니다. 재건축 전·멸실 등록은 근거를 적어 제외하세요.").font(.caption).foregroundStyle(.secondary)
                    Text(review.automatic && review.usable ? "대장 현황과 사용 상태로 자동 판별됨" : "중복·별개·과거 등록 판별 필요").font(.caption).foregroundStyle(review.usable ? Color.secondary : Color.orange)
                    if !review.conflicts.isEmpty {
                        Text("두 기기의 판별이 달라 공용 정보 적용을 보류했습니다. 아래 선택과 근거를 다시 확인해 확정하세요.").foregroundStyle(.orange)
                        ForEach(review.conflicts) { choice in Text(choice.reason).font(.caption) }
                    }
                }
                ForEach(review.candidates) { source in
                    Section(source.name + " · " + source.id) {
                        sourceDetails(source)
                        Picker("등록 판별",selection:Binding(get:{ review.excludedKaptIDs.contains(source.id) ? "__excluded__" : review.decision.groupForKapt[source.id,default:source.id] },set:{ setGroup(source.id,$0) })) {
                            Text("과거·멸실·현재 범위 밖 등록").tag("__excluded__")
                            ForEach(review.candidates.filter { !review.excludedKaptIDs.contains($0.id) || $0.id == source.id }) { other in
                                Text(other.id == source.id ? "별개 단지로 유지 · \(other.name) (\(other.id))" : "같은 관리단지 · \(other.name) (\(other.id))").tag(other.id)
                            }
                        }.pickerStyle(.menu)
                        if review.excludedKaptIDs.contains(source.id) {
                            NativeTextField("제외 근거 · 멸실/재건축/관리 범위 확인",text:Binding(get:{ review.decision.excludedKaptReasons?[source.id] ?? "" },set:{ value in
                                var values = review.decision.excludedKaptReasons ?? [:]; values[source.id] = value; review.decision.excludedKaptReasons = values; changed()
                            })).frame(minHeight:44)
                        }
                    }
                }
                ForEach(groupOptions) { group in
                    Section("채택할 현황 · " + group.name) {
                        Picker("현재 단지 정보의 원본",selection:Binding(get:{ review.decision.adoptedForGroup[group.id,default:group.id] },set:{ review.decision.adoptedForGroup[group.id] = $0; changed() })) {
                            ForEach(review.candidates.filter { review.decision.groupForKapt[$0.id] == group.id }) { source in
                                Text("\(source.name) · \(source.id) · \(source.fields["registrationStatus",default:"미확인"])").tag(source.id)
                            }
                        }
                        Toggle("채택한 원본이 이 관리단지 전체 범위임을 확인",isOn:Binding(get:{ (review.decision.wholeScopeGroups ?? []).contains(group.id) },set:{ value in
                            var roots = Set(review.decision.wholeScopeGroups ?? []); if value { roots.insert(group.id) } else { roots.remove(group.id) }
                            review.decision.wholeScopeGroups = roots.sorted(); changed()
                        }))
                        Text("여러 건물번호 전체 등록과 주소별 부분 등록을 더하지 않습니다. 모든 주소가 포함된 전체 등록을 선택하세요.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("건물별 관리단지 소속") {
                    Text("같은 총괄표제부라도 관리단지가 나뉘면 건물별로 지정하세요. 미확인 건물에는 단지 공용 수치를 적용하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    ForEach(review.buildings) { building in
                        VStack(alignment:.leading,spacing:4) {
                            Text([building.name,building.dongName].filter { !$0.isEmpty }.joined(separator:" ")).bold()
                            Text("건물 \(building.id) · 총괄 \(building.parentRegistryID ?? "미확인")").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            Picker("소속 단지",selection:Binding(get:{ review.decision.groupForBuilding[building.id] ?? "" },set:{ value in
                                if value.isEmpty { review.decision.groupForBuilding.removeValue(forKey:building.id) } else { review.decision.groupForBuilding[building.id] = value }; changed()
                            })) { groupChoices() }
                        }
                    }
                }
                if !review.realty.isEmpty {
                    Section("공시가격 원본의 관리단지 소속") {
                        Text("주소가 같아도 소속이 확인된 원본만 빈 건물 정보를 보충합니다.").font(.caption).foregroundStyle(.secondary)
                        ForEach(review.realty) { source in
                            VStack(alignment:.leading,spacing:4) {
                                Text(source.name).bold(); sourceDetails(source)
                                Picker("소속 단지",selection:Binding(get:{ review.decision.groupForRealty[source.id] ?? "" },set:{ value in
                                    if value.isEmpty { review.decision.groupForRealty.removeValue(forKey:source.id) } else { review.decision.groupForRealty[source.id] = value }; changed()
                                })) { groupChoices() }
                                Toggle("이 원본의 공용 수치가 해당 관리단지 전체 범위임을 확인",isOn:Binding(get:{ (review.decision.wholeRealtyIDs ?? []).contains(source.id) },set:{ value in
                                    var ids = Set(review.decision.wholeRealtyIDs ?? []); if value { ids.insert(source.id) } else { ids.remove(source.id) }
                                    review.decision.wholeRealtyIDs = ids.sorted(); changed()
                                }))
                            }
                        }
                    }
                }
                Section("판별 근거와 저장") {
                    NativeTextField("대장·단지 현황을 확인한 근거",text:$review.decision.reason).frame(minHeight:44)
                    Button("판별과 건물 소속을 확정·저장") { save() }.buttonStyle(.borderedProminent)
                    if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }.navigationTitle("단지 판별·건물 소속").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("닫기") { dismiss() } } }
        }
    }
    @ViewBuilder private func groupChoices() -> some View {
        Text("소속 미확인 · 공용 정보 보류").tag("")
        ForEach(groupOptions) { source in Text("\(source.name) · \(source.id)").tag(source.id) }
    }
    @ViewBuilder private func sourceDetails(_ source: BuildingComplexSource) -> some View {
        Text(source.roadAddresses.isEmpty ? "도로명주소 공란" : source.roadAddresses.joined(separator:"\n")).font(.caption).textSelection(.enabled)
        if !source.jibunAddress.isEmpty { Text(source.jibunAddress).font(.caption).foregroundStyle(.secondary) }
        Text("승인 \(source.fields["approvalDate",default:"미확인"]) · \(source.fields["buildings",default:"?"])동 · \(source.fields["households",default:"?"])세대").font(.caption)
        Text("주차 \(source.fields["parking",default:"미확인"])대 · \(source.fields["registrationStatus",default:"상태 미확인"])").font(.caption)
        Text("자료 확인 \(source.fetchedAt.formatted(date:.numeric,time:.shortened))").font(.caption2).foregroundStyle(.secondary)
    }
    private func changed() { review.automatic = false }
    private func setGroup(_ code: String, _ value: String) {
        var reasons = review.decision.excludedKaptReasons ?? [:]
        if value == "__excluded__" {
            reasons[code] = reasons[code] ?? ""; review.decision.groupForKapt.removeValue(forKey:code)
            for key in review.decision.groupForKapt.keys.sorted() where review.decision.groupForKapt[key] == code { review.decision.groupForKapt[key] = key }
        } else { reasons.removeValue(forKey:code); review.decision.groupForKapt[code] = value }
        review.decision.excludedKaptReasons = reasons; changed()
        do { try review.normalizeGroups(); message = nil } catch { message = error.localizedDescription }
    }
    private func save() {
        do {
            inputs.finishEditing(); try review.normalizeGroups()
            let prior = references.complexReview(review.roadAddress)
            var replaced = Set(review.supersedes)
            replaced.insert(review.decision.id)
            replaced.formUnion(review.conflicts.map(\.id))
            if let prior {
                replaced.insert(prior.decision.id)
                replaced.formUnion(prior.conflicts.map(\.id))
                replaced.formUnion(prior.supersedes)
            }
            review.supersedes = replaced.sorted()
            review.decision.id = UUID().uuidString; review.updatedAt = Date(); review.confirmed = true; review.conflicts = []
            try review.validate(); try references.saveComplexReview(review)
            try sites.applyComplexReviews(references.complexReviews)
            guard let saved = references.complexReview(review.roadAddress), saved.usable else { throw BuildingEvaluationError.message("판별 충돌이 남아 있습니다. 원본을 비교해 다시 확정하세요.") }
            onSaved(saved); dismiss()
        } catch { message = error.localizedDescription }
    }
}
