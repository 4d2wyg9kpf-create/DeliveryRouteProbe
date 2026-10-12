import Foundation
import Combine

@MainActor
final class HousingStore: ObservableObject {
    @Published private(set) var regions: [HousingRegionSummary] = []
    @Published private(set) var edits: [HousingEdit] = []
    @Published private(set) var complexes: [HousingComplex] = []
    @Published var errorMessage: String?
    @Published var progress = ""
    @Published var collectionProgress: HousingCollectionProgress?
    @Published var isBusy = false
    @Published private(set) var hasAddressKey = false
    private var addressKey = ""
    private let directory: URL
    private var index: HousingIndex?
    private var searchRegion = ""
    private var searchKeyword = ""
    private var syncFolderIdentity = ""
    private var writable = true
    private var published = Set<String>()
    private var ready = Set<String>()
    init(directory: URL? = nil, seedIfEmpty: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteProbe/Housing", isDirectory: true)
        do {
            index = try HousingIndex(directory: self.directory)
            regions = try index!.summaries()
            if FileManager.default.fileExists(atPath: self.directory.path) {
                for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("region-") && file.pathExtension == "json" {
                    let code = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "region-", with: "")
                    if !regions.contains(where: { $0.code == code }) { let region = try Self.decode(Data(contentsOf: file)); try index!.replace(region); regions.append(HousingRegionSummary(region)) }
                }
                let file = self.directory.appendingPathComponent("edits.json")
                if FileManager.default.fileExists(atPath: file.path) { edits = try DeviceShareCodec.decode([HousingEdit].self, Data(contentsOf: file)); try Self.validate(edits) }
                // Migrate the previous raw-only index. Raw files and edits are
                // retained; explicit user links are the only grouping decisions.
                for summary in regions where summary.manualReview != true || edits.contains(where: { $0.regionCode == summary.code }) {
                    let region = try originalRegion(summary.code); try index!.replace(region, edits: edits)
                }
                regions = try index!.summaries()
            }
            let secure = try APIProtectedStateFile(.housingAddress,directory:self.directory.appendingPathComponent("secure"))
            if let data = try secure.read() { let key = try DeviceShareCodec.decode(String.self,data); try Self.validateAddressKey(key); addressKey = key; hasAddressKey = !key.isEmpty }
            if seedIfEmpty, !regions.contains(where: { $0.code == "1168010300" }) {
                let seed = try Self.decode(Data(HousingSeed.source.utf8)); try importRegion(seed, share: false)
            }
            ready = Set(regions.map(\.code)); publish()
        } catch { writable = false; errorMessage = "공동주택 보관 자료를 읽지 못했습니다. 기존 자료는 보존했습니다. " + error.localizedDescription }
    }
    private func publish() {
        regions.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        do {
            let sources = try index?.search(region: searchRegion, keyword: searchKeyword, sourceIDs: Set(edits.flatMap(\.sourceIDs))) ?? []
            complexes = HousingCatalog.effective(sources: sources, edits: edits).filter { (searchRegion.isEmpty || $0.regionCode == searchRegion || $0.originals.contains { $0.regionCode == searchRegion }) && (searchKeyword.isEmpty || $0.searchText.localizedCaseInsensitiveContains(searchKeyword)) }
        } catch { errorMessage = error.localizedDescription }
    }
    func search(region: String, keyword: String) async {
        searchRegion = region; searchKeyword = keyword
        let edits = edits, directory = directory, ids = Set(edits.flatMap(\.sourceIDs))
        do {
            let sources = try await Task.detached(priority: .utility) { try HousingIndex.search(directory: directory, region: region, keyword: keyword, sourceIDs: ids) }.value
            guard searchRegion == region, searchKeyword == keyword else { return }
            complexes = HousingCatalog.effective(sources: sources, edits: edits).filter { (region.isEmpty || $0.regionCode == region || $0.originals.contains { $0.regionCode == region }) && (keyword.isEmpty || $0.searchText.localizedCaseInsensitiveContains(keyword)) }
        } catch { errorMessage = error.localizedDescription }
    }
    func originalRegion(_ code: String) throws -> HousingRegion { try Self.decode(Data(contentsOf: directory.appendingPathComponent("region-" + code + ".json"))) }
    func exportRegions(_ code: String) throws -> [HousingRegion] {
        let selected = regions.filter { code.isEmpty || $0.code == code }
        guard !code.isEmpty || selected.reduce(0, { $0 + $1.sourceCount }) <= 20_000 else { throw PlannerFailure.message("큰 자료는 법정동을 선택해 나누어 내보내세요.") }
        return try selected.map { try originalRegion($0.code) }
    }
    nonisolated static func decode(_ data: Data) throws -> HousingRegion {
        guard data.count <= 50_000_000 else { throw DeviceShareError.invalid }
        let region = try JSONDecoder().decode(HousingRegion.self, from: data); try region.validate(); return region
    }
    nonisolated static func validate(_ edits: [HousingEdit]) throws {
        guard edits.count <= 5_000, Set(edits.map(\.id)).count == edits.count,
              edits.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 200 && $0.sourceIDs.count <= 500 && ($0.mergedIDs?.count ?? 0) <= 500 && !($0.mergedIDs ?? []).contains($0.id) && $0.fields.count <= 100 && ($0.note?.utf8.count ?? 0) <= 20_000 && $0.fields.values.allSatisfy({ $0.utf8.count <= 20_000 }) && ($0.coordinate.map(KakaoRouteAPI.valid) ?? true) }) else { throw DeviceShareError.invalid }
    }
    func importRegion(_ incoming: HousingRegion, share: Bool = true) throws {
        var region = incoming
        guard writable else { throw DeviceShareError.unavailable }; try region.validate()
        let existing = regions.first { $0.code == region.code }
        if existing != nil {
            let local = try originalRegion(region.code), merged = try local.merging(region)
            if try DeviceShareCodec.encode(merged) == DeviceShareCodec.encode(local) { return }
            region = merged
            if merged.generation <= local.generation { region.generation = max(Date().timeIntervalSince1970 * 1000, local.generation + 1) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DeviceShareCodec.encode(region).write(to: directory.appendingPathComponent("region-" + region.code + ".json"), options: .atomic)
        try index?.replace(region, edits: edits)
        regions.removeAll { $0.code == region.code }; regions.append(HousingRegionSummary(region)); publish()
        if share { ready.insert(region.code); try DeviceShareHooks.changed() } else { ready.remove(region.code) }
    }
    func shareRegion(_ code: String) throws { ready.insert(code); try DeviceShareHooks.changed() }
    func updateCollectionProgress(_ update: (inout HousingCollectionProgress) -> Void) {
        guard var value = collectionProgress else { return }
        update(&value); collectionProgress = value; progress = value.text
    }
    func collectRealtyRegion(_ target: HousingCollectionTarget, details: Bool,
                             client: any RealtyHousingCollecting) async throws -> Bool {
        let code = target.id
        updateCollectionProgress { $0.beginRegion(id: code, title: target.title) }
        try Task.checkCancellation()
        let listed = try await client.list(sido: target.sido, sigungu: target.sigungu, dong: target.dong)
        try Task.checkCancellation(); try importRegion(listed)
        guard details else { return true }
        defer { try? shareRegion(code) }
        var region = try originalRegion(code)
        let missingIDs = region.missingDetailIDs
        updateCollectionProgress { $0.beginDetails(ids: missingIDs, previouslyCompleted: region.detailCount) }
        for id in missingIDs {
            try Task.checkCancellation(); region = try originalRegion(code)
            guard let index = region.records.firstIndex(where: { $0.id == id }) else {
                updateCollectionProgress { $0.detailFinished(id, successful: false) }; continue
            }
            if region.records[index].detailAt != nil {
                updateCollectionProgress { $0.detailFinished(id, successful: true) }; continue
            }
            do {
                region.records[index] = try await client.detail(region.records[index])
                if region.records[index].fields["roadAddress", default: ""].isEmpty, KakaoRouteStore.shared.settings.mapFreeConfirmed, !KakaoRouteStore.shared.settings.key.isEmpty {
                    do { if let road = try await KakaoRouteStore.shared.roadAddress(for: region.records[index]) { region.records[index].fields["roadAddress"] = road; region.records[index].issues.removeAll { $0.contains("도로명주소") } } }
                    catch is CancellationError { throw CancellationError() }
                    catch { region.records[index].issues.append("주소 변환: " + error.localizedDescription) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { region.records[index].issues = [error.localizedDescription] }
            try Task.checkCancellation()
            region.generation = max(Date().timeIntervalSince1970 * 1000, region.generation + 1)
            try importRegion(region, share: false)
            updateCollectionProgress { $0.detailFinished(id, successful: region.records[index].detailAt != nil) }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let completed = Set(try originalRegion(code).records.filter { $0.detailAt != nil }.map(\.id))
        updateCollectionProgress { value in
            for id in missingIDs where completed.contains(id) { value.detailFinished(id, successful: true) }
        }
        return missingIDs.allSatisfy(completed.contains)
    }
    func edit(_ complex: HousingComplex, fields: [String: String], coordinate: TMapCoordinate? = nil) throws {
        var next = edits; let index = next.firstIndex { $0.id == complex.id }
        var value = index.map { next[$0] } ?? HousingEdit(id: complex.id, sourceIDs: complex.sourceIDs, regionCode: complex.regionCode)
        value.fields.merge(fields) { _, incoming in incoming }; if let coordinate { value.coordinate = coordinate }
        if let index { next[index] = value } else { next.append(value) }; try commit(next)
    }
    func importEdits(_ incoming: [HousingEdit]) throws {
        try Self.validate(incoming)
        var next = Dictionary(edits.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for edit in incoming { next[edit.id] = edit }; try commit(next.values.sorted { $0.id < $1.id })
    }
    func reset(_ id: String) throws {
        var next = edits.filter { $0.id != id }
        for i in next.indices where next[i].note == "통합:" + id { next[i].hidden = false; next[i].note = nil }
        try commit(next)
    }
    func restore(_ id: String) throws {
        var next = edits; guard let index = next.firstIndex(where: { $0.id == id }) else { return }; next[index].hidden = false; try commit(next)
    }
    func hide(_ complex: HousingComplex) throws {
        var next = edits
        var value = next.first { $0.id == complex.id } ?? HousingEdit(id:complex.id,sourceIDs:complex.sourceIDs,regionCode:complex.regionCode)
        value.hidden = true; next.removeAll { $0.id == complex.id }; next.append(value); try commit(next)
    }
    @discardableResult
    func add(name: String, regionCode: String, fields: [String: String] = [:], coordinate: TMapCoordinate? = nil, sourceIDs: [String] = []) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerFailure.message("단지명을 입력하세요.") }
        var fields = fields; fields[HousingField.name.rawValue] = name
        let id = "user:" + UUID().uuidString
        try commit(edits + [HousingEdit(id: id, sourceIDs: sourceIDs, regionCode: regionCode, fields: fields, coordinate: coordinate)]); return id
    }
    func merge(_ ids: Set<String>, name: String, reviewed: [HousingComplex]? = nil) throws {
        let selected = (reviewed ?? complexes).filter { ids.contains($0.id) }; guard selected.count == ids.count, selected.count > 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlannerFailure.message("단지를 2개 이상 선택하고 합칠 이름을 입력하세요.") }
        var next = edits
        let mergedID = "user:" + UUID().uuidString
        for complex in selected {
            var previous = next.first(where: { $0.id == complex.id }) ?? HousingEdit(id: complex.id,sourceIDs: complex.sourceIDs,regionCode: complex.regionCode)
            previous.hidden = true; previous.note = "통합:" + mergedID
            next.removeAll { $0.id == complex.id }; next.append(previous)
        }
        next.append(HousingEdit(id: mergedID, sourceIDs: Array(Set(selected.flatMap(\.sourceIDs))).sorted(), regionCode: selected[0].regionCode,
            fields: ["name":name], coordinate: selected[0].coordinate,mergedIDs:selected.map(\.id)))
        try commit(next)
    }
    func reviewCandidates(_ complex: HousingComplex) throws -> [HousingComplex] {
        let codes = Set(complex.originals.map(\.regionCode)).union([complex.regionCode]).filter { !$0.isEmpty }
        let raw = try codes.map { try originalRegion($0) }
        let candidates = HousingCatalog.effective(regions:raw,edits:edits)
        return candidates.filter { other in
            other.id == complex.id || (complex.originals + [HousingSource(id:complex.id,aptCode:complex.id,noticeDate:"",regionCode:complex.regionCode,fields:complex.fields)]).contains { a in (other.originals + [HousingSource(id:other.id,aptCode:other.id,noticeDate:"",regionCode:other.regionCode,fields:other.fields)]).contains { b in
                HousingIdentity.sameRoad(a,b) || (!HousingIdentity.parcel(a).isEmpty && HousingIdentity.parcel(a) == HousingIdentity.parcel(b)) || (!HousingIdentity.office(a).isEmpty && HousingIdentity.office(a) == HousingIdentity.office(b))
            } }
        }
    }
    private func commit(_ next: [HousingEdit]) throws {
        guard writable else { throw DeviceShareError.unavailable }; try Self.validate(next)
        let old = Dictionary(edits.map { ($0.id,$0) },uniquingKeysWith:{ _,newer in newer })
        let newer = Dictionary(next.map { ($0.id,$0) },uniquingKeysWith:{ _,newer in newer })
        let changed = Set(old.keys).union(newer.keys).filter { key in
            (try? DeviceShareCodec.encode(old[key])) != (try? DeviceShareCodec.encode(newer[key]))
        }
        let codes = Set(changed.compactMap { newer[$0]?.regionCode ?? old[$0]?.regionCode })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DeviceShareCodec.encode(next).write(to: directory.appendingPathComponent("edits.json"), options: .atomic)
        edits = next
        // Source corrections update search text; grouping stays explicitly chosen.
        for summary in regions where codes.contains(summary.code) { try index?.replace(originalRegion(summary.code), edits: edits) }
        regions = try index?.summaries() ?? regions; publish(); try DeviceShareHooks.changed()
    }
    func sharingSnapshot() throws -> DeviceShareSnapshot {
        guard writable else { throw DeviceShareError.unavailable }; var result = DeviceShareSnapshot()
        for edit in edits { result.values["housing/" + edit.id] = try DeviceShareCodec.encode(edit) }
        result.append(try addressSnapshot()); return result
    }
    func applySharing(_ replica: DeviceShareReplica) throws {
        if let key = try replica.value("setting/housing-address",as:String.self), !key.isEmpty, key != addressKey { try saveAddressKey(key) }
        var next: [HousingEdit] = []
        for (key, record) in replica.records where key.hasPrefix("housing/") {
            if let data = record.value { let edit = try DeviceShareCodec.decode(HousingEdit.self, data); guard key == "housing/" + edit.id else { throw DeviceShareError.invalid }; next.append(edit) }
        }
        next.sort { $0.id < $1.id }
        if try DeviceShareCodec.encode(next) != DeviceShareCodec.encode(edits.sorted { $0.id < $1.id }) { try commit(next) }
    }
    nonisolated static func validateAddressKey(_ key: String) throws {
        guard key.isEmpty || key.range(of: #"^[A-Za-z0-9_+=/-]{10,200}$"#,options:.regularExpression) != nil else { throw PlannerFailure.message("도로명주소 API 승인키 형식을 확인하세요.") }
    }
    func saveAddressKey(_ entered: String) throws {
        guard writable else { throw DeviceShareError.unavailable }
        let key = entered.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty else { return }; try Self.validateAddressKey(key)
        let file = try APIProtectedStateFile(.housingAddress,directory:directory.appendingPathComponent("secure"))
        try file.write(DeviceShareCodec.encode(key)); addressKey = key; hasAddressKey = true; try DeviceShareHooks.changed()
    }
    func addressSnapshot() throws -> DeviceShareSnapshot {
        var snapshot = DeviceShareSnapshot(); if hasAddressKey { snapshot.values["setting/housing-address"] = try DeviceShareCodec.encode(addressKey) }; return snapshot
    }
    func enrichAddress(_ source: HousingSource) async throws -> HousingSource {
        try await DeviceShareHooks.prepareRequest()
        if RealtyHousingClient.road(source.fields["roadAddress"] ?? ""), let region = try? originalRegion(source.regionCode),
           let cached = (region.records + (region.kaptRecords ?? [])).first(where: { $0.id != source.id && !($0.addresses ?? []).isEmpty && HousingIdentity.sameRoad(source,$0) }) {
            var next = source; next.addresses = cached.addresses
            next.fields["communityCenter"] = cached.fields["communityCenter"]
            next.fields["jusoDongNames"] = cached.fields["jusoDongNames"]; return next
        }
        return try await HousingAddressClient().lookup(source,key:addressKey)
    }
    func rawSource(_ id: String) throws -> HousingSource? {
        try index?.search(region:"",keyword:"\u{0001}",sourceIDs:[id]).first { $0.id == id }
    }
    func saveSourceOverride(_ source: HousingSource, fields: [String:String], confirmedDongs: Bool, excluded: Bool = false) throws {
        var next = edits; var value = next.first { $0.id == source.id } ?? HousingEdit(id:source.id,sourceIDs:[source.id],regionCode:source.regionCode)
        value.fields.merge(fields) { _, user in user }; value.dongScopeConfirmed = confirmedDongs; value.hidden = excluded; value.sourceExcluded = excluded
        next.removeAll { $0.id == source.id }; next.append(value); try commit(next)
    }
    func attachKapt(_ complex: HousingComplex, sourceIDs: Set<String>, wholeID: String?, useWholeName: Bool = false) throws {
        guard sourceIDs.allSatisfy({ $0.hasPrefix("kapt:") }), wholeID == nil || sourceIDs.contains(wholeID!) else { throw DeviceShareError.invalid }
        let sources = try sourceIDs.compactMap { try rawSource($0) }; guard sources.count == sourceIDs.count else { throw DeviceShareError.invalid }
        var next = edits; var value = next.first { $0.id == complex.id } ?? HousingEdit(id:complex.id,sourceIDs:complex.sourceIDs,regionCode:complex.regionCode)
        value.sourceIDs = (complex.sourceIDs.filter { !$0.hasPrefix("kapt:") } + Array(sourceIDs)).sorted()
        value.preferredKaptID = wholeID
        if useWholeName, let whole = sources.first(where: { $0.id == wholeID }) { value.fields["name"] = whole.fields["name"] }
        next.removeAll { $0.id == complex.id }; next.append(value); try commit(next)
    }
    func collectKapt(_ code: String, refresh: Bool, api: PublicDataStore) async throws {
        var region = try originalRegion(code)
        defer { try? shareRegion(code) }
        do {
            var existing = Dictionary((region.kaptRecords ?? []).map { ($0.id,$0) },uniquingKeysWith:HousingRegion.newerSource)
            var seen = Set<String>(), total: Int?
            for page in 1...1000 {
                try Task.checkCancellation(); progress = "\(region.title) · K-apt 목록 \(page)페이지"
                let result = try KaptHousingClient.list(await api.kaptData(.list,parameters:["bjdCode":code,"pageNo":String(page)]),region:code,page:page)
                if let total, total != result.total { throw PlannerFailure.message("K-apt 전체 건수가 변경되어 수집을 보류했습니다.") }; total = result.total
                for source in result.records { guard seen.insert(source.id).inserted else { throw DeviceShareError.invalid }; if existing[source.id] == nil { existing[source.id] = source } }
                region.kaptRecords = existing.values.sorted { $0.id < $1.id }; region.generation = max(Date().timeIntervalSince1970 * 1000,region.generation + 1)
                if seen.count == result.total { region.kaptListAt = Date() }
                try importRegion(region,share:false)
                if seen.count == result.total { break }
                guard page < 1000 else { throw PlannerFailure.message("K-apt 목록 수집 범위를 확인하세요.") }
                try await Task.sleep(nanoseconds:300_000_000)
            }
        }
        let pending = (region.kaptRecords ?? []).filter { refresh || $0.detailAt == nil }.map(\.id)
        for (number,id) in pending.enumerated() {
            try Task.checkCancellation(); region = try originalRegion(code)
            guard let position = region.kaptRecords?.firstIndex(where:{ $0.id == id }), let source = region.kaptRecords?[position] else { continue }
            progress = "\(region.title) · K-apt 상세 \(number+1)/\(pending.count)"
            let base = try await api.kaptData(.basic,parameters:["kaptCode":source.aptCode])
            try await Task.sleep(nanoseconds:300_000_000)
            let facilities = try await api.kaptData(.facilities,parameters:["kaptCode":source.aptCode])
            var updated = try KaptHousingClient.detail(basic:base,facilities:facilities,source:source)
            if hasAddressKey {
                do { updated = try await enrichAddress(updated) }
                catch is CancellationError { throw CancellationError() }
                catch { updated.issues.append("주소 확인: " + error.localizedDescription) }
            }
            region = try originalRegion(code)
            guard let i = region.kaptRecords?.firstIndex(where:{ $0.id == id }) else { continue }
            region.kaptRecords?[i] = updated; region.generation = max(Date().timeIntervalSince1970 * 1000,region.generation + 1); try importRegion(region,share:false)
            try await Task.sleep(nanoseconds:300_000_000)
        }
        progress = "\(region.title) · K-apt 원본 수집 완료. 연결과 통합은 직접 확인하세요."
    }
    func collectAddresses(_ code: String) async throws {
        var region = try originalRegion(code); defer { try? shareRegion(code) }
        let ids = (region.records + (region.kaptRecords ?? [])).filter { ($0.addresses ?? []).isEmpty }.map(\.id)
        for (number,id) in ids.enumerated() {
            try Task.checkCancellation(); progress = "\(region.title) · 주소 확인 \(number+1)/\(ids.count)"
            region = try originalRegion(code)
            guard let raw = (region.records + (region.kaptRecords ?? [])).first(where:{ $0.id == id }) else { continue }
            let next = try await enrichAddress(raw)
            region = try originalRegion(code)
            if let i = region.records.firstIndex(where:{ $0.id == id }) { region.records[i] = next }
            else if let i = region.kaptRecords?.firstIndex(where:{ $0.id == id }) { region.kaptRecords?[i] = next }
            region.generation = max(Date().timeIntervalSince1970 * 1000,region.generation + 1); try importRegion(region,share:false)
            try await Task.sleep(nanoseconds:300_000_000)
        }
    }
    // Immutable source snapshots are separate from the small per-device edit replicas.
    // Different collectors never overwrite the same shared source file.
    func synchronizeSources(_ folder: URL) async throws {
        guard writable else { throw DeviceShareError.unavailable }
        if syncFolderIdentity != folder.absoluteString { published.removeAll(); ready.formUnion(regions.map(\.code)); syncFolderIdentity = folder.absoluteString }
        let current = Dictionary(regions.map { ($0.code, $0.generation) }, uniquingKeysWith: max)
        let incoming = try await Task.detached(priority: .utility) { try HousingFolderIO.read(folder, current: current) }.value
        for name in incoming {
            let region = try await Task.detached(priority: .utility) { try HousingFolderIO.readFile(name, folder: folder) }.value
            try importRegion(region, share: false)
        }
        for summary in regions where ready.contains(summary.code) {
            let data = try DeviceShareCodec.encode(originalRegion(summary.code))
            let key = summary.code + "-" + String(Int(summary.generation)) + "-" + DeviceShareCodec.digest(data).prefix(12)
            guard !published.contains(key) else { continue }
            try await Task.detached(priority: .utility) { try HousingFolderIO.write([(key, data)], folder: folder) }.value
            published.insert(key)
            if regions.first(where: { $0.code == summary.code })?.generation == summary.generation { ready.remove(summary.code) }
        }
    }
}
enum HousingFolderIO {
    static func read(_ folder: URL, current: [String: Double]) throws -> [String] {
        let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let directory = folder.appendingPathComponent("DeliveryRouteShare/housing-originals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var coordinationError: NSError?; var result: [String] = []; var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &coordinationError) { root in
            do {
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]); guard files.count <= 100_000 else { throw DeviceShareError.invalid }
                var latest: [String: (Double, String)] = [:]
                for file in files where file.pathExtension == "json" {
                    let name = file.deletingPathExtension().lastPathComponent, parts = name.split(separator: "-")
                    guard parts.count == 3, parts[0].count == 10, parts[2].count == 12, let generation = Double(parts[1]), generation > (current[String(parts[0])] ?? 0) else { continue }
                    let code = String(parts[0])
                    if latest[code] == nil || latest[code]!.0 < generation { latest[code] = (generation, name) }
                }
                result = latest.values.map(\.1).sorted()
            } catch { failure = error }
        }
        if let failure { throw failure }; if coordinationError != nil { throw DeviceShareError.unavailable }; return result
    }
    static func readFile(_ name: String, folder: URL) throws -> HousingRegion {
        guard name.range(of: #"^\d{10}-\d{1,16}-[a-f0-9]{12}$"#, options: .regularExpression) != nil else { throw DeviceShareError.invalid }
        let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent("DeliveryRouteShare/housing-originals/" + name + ".json")
        var coordinationError: NSError?; var result: Result<HousingRegion, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            result = Result {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 50_000_000 else { throw DeviceShareError.invalid }
                let data = try Data(contentsOf: url), region = try HousingStore.decode(data), parts = name.split(separator: "-")
                guard region.code == String(parts[0]), Int(region.generation) == Int(parts[1]), DeviceShareCodec.digest(data).hasPrefix(String(parts[2])) else { throw DeviceShareError.invalid }
                return region
            }
        }
        if coordinationError != nil { throw DeviceShareError.unavailable }; guard let result else { throw DeviceShareError.unavailable }; return try result.get()
    }
    static func write(_ values: [(String, Data)], folder: URL) throws {
        guard !values.isEmpty else { return }
        let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
        var error: NSError?; var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &error) { root in
            do {
                let directory = root.appendingPathComponent("DeliveryRouteShare/housing-originals", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (name, data) in values {
                    let file = directory.appendingPathComponent(name + ".json")
                    if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
                }
            } catch { failure = error }
        }
        if let failure { throw failure }; if error != nil { throw DeviceShareError.unavailable }
    }
}
