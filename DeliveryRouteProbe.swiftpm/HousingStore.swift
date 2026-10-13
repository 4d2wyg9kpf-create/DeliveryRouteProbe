import Foundation
import Combine

@MainActor
final class HousingStore: ObservableObject {
    @Published private(set) var regions: [HousingRegionSummary] = []
    @Published private(set) var edits: [HousingEdit] = []
    @Published private(set) var complexes: [HousingComplex] = []
    @Published var errorMessage: String?
    @Published var progress = ""
    let collectionStatus = HousingCollectionStatus()
    var collectionProgress: HousingCollectionProgress? {
        get { collectionStatus.value }
        set { collectionStatus.value = newValue }
    }
    @Published var isBusy = false
    @Published private(set) var resumableScopeTitle: String?
    @Published private(set) var hasAddressKey = false
    private var addressKey = ""
    private let directory: URL
    private var index: HousingIndex?
    private var collectionDisk: HousingCollectionDisk?
    private var collectionTask: Task<Void, Never>?
    private var collectionRunID: UUID?
    private var pendingSummaries: [String: HousingRegionSummary] = [:]
    private var lastCollectionRefresh = Date.distantPast
    private var editsRevision = 0
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
            collectionDisk = HousingCollectionDisk(directory: self.directory, index: index!)
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
                try collectionDisk!.recover(edits: edits)
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
            if let checkpoint = try index?.collectionCheckpoint() { resumableScopeTitle = checkpoint.scope.title }
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
        let edits = edits, revision = editsRevision, directory = directory, ids = Set(edits.flatMap(\.sourceIDs))
        do {
            let result = try await Task.detached(priority: .utility) {
                let sources = try HousingIndex.search(directory: directory, region: region, keyword: keyword, sourceIDs: ids)
                return HousingCatalog.effective(sources: sources, edits: edits).filter { (region.isEmpty || $0.regionCode == region || $0.originals.contains { $0.regionCode == region }) && (keyword.isEmpty || $0.searchText.localizedCaseInsensitiveContains(keyword)) }
            }.value
            guard searchRegion == region, searchKeyword == keyword, editsRevision == revision else { return }
            complexes = result
        } catch { errorMessage = error.localizedDescription }
    }
    func originalRegion(_ code: String) throws -> HousingRegion {
        guard let collectionDisk else { throw DeviceShareError.unavailable }; return try collectionDisk.read(code)
    }
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
        guard writable, let collectionDisk else { throw DeviceShareError.unavailable }
        let summary = try collectionDisk.merge(incoming, edits: edits)
        regions.removeAll { $0.code == summary.code }; regions.append(summary); publish()
        if share { ready.insert(summary.code); try DeviceShareHooks.changed() } else { ready.remove(summary.code) }
    }
    func shareRegion(_ code: String) throws { ready.insert(code); try DeviceShareHooks.changed() }
    func updateCollectionProgress(_ update: (inout HousingCollectionProgress) -> Void) {
        guard var value = collectionProgress else { return }
        update(&value); collectionProgress = value
        if let id = collectionRunID { HousingCollectionBackground.shared.update(id: id, progress: value) }
    }
    private func importCollectedRegion(_ incoming: HousingRegion) async throws -> HousingRegion {
        guard writable, let disk = collectionDisk else { throw DeviceShareError.unavailable }
        let changes = edits, revision = editsRevision
        let region = try await Task.detached(priority: .utility) {
            _ = try disk.merge(incoming, edits: changes); return try disk.read(incoming.code)
        }.value
        if editsRevision != revision {
            let latest = edits
            try await Task.detached(priority: .utility) { try disk.flush(incoming.code, reindex: true, edits: latest) }.value
        }
        pendingSummaries[incoming.code] = HousingRegionSummary(region); ready.insert(incoming.code)
        return region
    }
    private func refreshCollectedUI(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastCollectionRefresh) >= 3 else { return }
        lastCollectionRefresh = Date()
        let changes = pendingSummaries; pendingSummaries.removeAll()
        if !changes.isEmpty {
            let current = regions
            regions = await Task.detached(priority: .utility) {
                var values = Dictionary(current.map { ($0.code, $0) }, uniquingKeysWith: { a, b in b.generation >= a.generation ? b : a })
                for (code, value) in changes where value.generation >= (values[code]?.generation ?? 0) { values[code] = value }
                return values.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }.value
        }
        await search(region: searchRegion, keyword: searchKeyword)
    }
    func startRealtyCollection(scope: HousingCollectionScope, details: Bool, client: any RealtyHousingCollecting = RealtyHousingClient()) {
        startRealtyJob(HousingCollectionCheckpoint(scope: scope, includesDetails: details), resuming: false, client: client)
    }
    func resumeRealtyCollection(client: any RealtyHousingCollecting = RealtyHousingClient()) {
        do {
            guard let checkpoint = try index?.collectionCheckpoint() else { resumableScopeTitle = nil; return }
            startRealtyJob(checkpoint, resuming: true, client: client)
        } catch { errorMessage = error.localizedDescription }
    }
    private func startRealtyJob(_ checkpoint: HousingCollectionCheckpoint, resuming: Bool, client: any RealtyHousingCollecting) {
        guard !isBusy, writable else { return }
        let id = UUID(); collectionRunID = id; isBusy = true; errorMessage = nil
        collectionProgress = HousingCollectionProgress(scopeTitle: checkpoint.scope.title, includesDetails: checkpoint.includesDetails)
        collectionStatus.resumeAt = nil; lastCollectionRefresh = .distantPast
        HousingCollectionBackground.shared.begin(id: id, title: checkpoint.scope.title, status: collectionStatus, start: { [weak self] in
            guard let self, self.collectionRunID == id else { return }
            self.collectionTask = Task { [weak self] in
                guard let self else { return }
                var succeeded = false
                do { succeeded = try await self.runRealtyCollection(checkpoint, resuming: resuming, client: client) }
                catch is CancellationError { self.updateCollectionProgress { $0.stop() } }
                catch {
                    self.errorMessage = error.localizedDescription
                    self.collectionStatus.resumeAt = (error as? RealtyCollectionInterruption)?.resumeAt
                    self.updateCollectionProgress { $0.fail() }
                }
                await self.refreshCollectedUI(force: true)
                try? DeviceShareHooks.changed()
                HousingCollectionBackground.shared.finish(id: id, success: succeeded)
                self.resumableScopeTitle = (try? self.index?.collectionCheckpoint())?.scope.title
                self.isBusy = false; self.collectionTask = nil; self.collectionRunID = nil
                if succeeded { self.collectionStatus.backgroundMessage = "수집을 완료했습니다." }
            }
        }, expire: { [weak self] in
            self?.collectionStatus.backgroundMessage = "시스템이 백그라운드 수집을 중단했습니다. 저장된 작업을 이어서 수집할 수 있습니다."
            self?.stopRealtyCollection(system: true)
        })
    }
    func stopRealtyCollection(system: Bool = false) {
        if !system { collectionStatus.backgroundMessage = "수집을 중단하고 작업을 보관합니다." }
        if let task = collectionTask { task.cancel() }
        else if let id = collectionRunID {
            HousingCollectionBackground.shared.finish(id: id, success: false)
            collectionRunID = nil; isBusy = false; updateCollectionProgress { $0.stop() }
        }
    }
    func waitForRealtyCollection() async { await collectionTask?.value }
    // Kept independently of any View task, so tab switches and navigation do
    // not cancel the user's job. The durable inventory also survives relaunch.
    func runRealtyCollection(_ saved: HousingCollectionCheckpoint, resuming: Bool,
                            client: any RealtyHousingCollecting) async throws -> Bool {
        guard let disk = collectionDisk else { throw DeviceShareError.unavailable }
        var checkpoint = saved
        try await DeviceShareHooks.prepareRequest()
        try await Task.detached(priority: .utility) { try disk.index.saveCollectionCheckpoint(saved, resetInventory: !resuming) }.value
        resumableScopeTitle = saved.scope.title
        if checkpoint.targets == nil {
            checkpoint.targets = try await HousingCollectionTargets.resolve(checkpoint.scope, client: client) { count in self.updateCollectionProgress { $0.discovered(count) } }
            let request = checkpoint
            try await Task.detached(priority: .utility) { try disk.index.saveCollectionCheckpoint(request, resetInventory: false) }.value
        }
        let targets = checkpoint.targets ?? []
        updateCollectionProgress { $0.setTargets(targets.map(\.id)) }
        for target in targets {
            try Task.checkCancellation()
            updateCollectionProgress { $0.beginRegion(id: target.id, title: target.title) }
            let region: HousingRegion
            if checkpoint.inventory[target.id] != nil {
                region = try await Task.detached(priority: .utility) { try disk.read(target.id) }.value
            } else {
                let listed = try await client.list(sido: target.sido, sigungu: target.sigungu, dong: target.dong)
                try Task.checkCancellation(); region = try await importCollectedRegion(listed)
                let ids = region.records.map(\.id)
                try await Task.detached(priority: .utility) { try disk.index.recordCollectionInventory(region: target.id, ids: ids) }.value
                checkpoint.inventory[target.id] = ids
            }
            let ids = checkpoint.inventory[target.id] ?? []
            let completed = Set(region.records.filter { $0.detailAt != nil }.map(\.id))
            updateCollectionProgress { $0.recordInventory(regionID: target.id, ids: ids, completedIDs: completed) }
            await refreshCollectedUI()
        }
        updateCollectionProgress { $0.sealInventory() }
        var complete = true
        if checkpoint.includesDetails {
            for target in targets {
                try Task.checkCancellation()
                let success = try await collectRealtyRegion(target, details: true, client: client, inventoryIDs: checkpoint.inventory[target.id])
                updateCollectionProgress { $0.regionFinished(successful: success) }; complete = complete && success
            }
        }
        updateCollectionProgress { $0.finish() }
        if complete {
            try await Task.detached(priority: .utility) { try disk.index.clearCollectionCheckpoint() }.value
            resumableScopeTitle = nil
        }
        return complete
    }
    func collectRealtyRegion(_ target: HousingCollectionTarget, details: Bool,
                             client: any RealtyHousingCollecting, inventoryIDs: [String]? = nil) async throws -> Bool {
        guard let disk = collectionDisk else { throw DeviceShareError.unavailable }
        let code = target.id
        updateCollectionProgress { $0.beginRegion(id: code, title: target.title) }
        try Task.checkCancellation()
        let region: HousingRegion
        if inventoryIDs == nil {
            let listed = try await client.list(sido: target.sido, sigungu: target.sigungu, dong: target.dong)
            try Task.checkCancellation(); region = try await importCollectedRegion(listed)
            let completed = Set(region.records.filter { $0.detailAt != nil }.map(\.id))
            updateCollectionProgress { $0.recordInventory(regionID: code, ids: region.records.map(\.id), completedIDs: completed); $0.sealInventory() }
        } else { region = try await Task.detached(priority: .utility) { try disk.read(code) }.value }
        guard details else { return true }
        let selected = Set(inventoryIDs ?? region.records.map(\.id))
        let completeIDs = Set(region.records.filter { $0.detailAt != nil && selected.contains($0.id) }.map(\.id))
        let missingIDs = (inventoryIDs ?? region.records.map(\.id)).filter { !completeIDs.contains($0) }
        updateCollectionProgress { $0.reconcileCompleted(regionID: code, ids: completeIDs); $0.beginDetails(ids: missingIDs, previouslyCompleted: completeIDs.count) }
        var consecutiveFailures = 0
        do {
            for (number, id) in missingIDs.enumerated() {
                try Task.checkCancellation()
                guard var source = try await Task.detached(priority: .utility, operation: { try disk.source(id, code: code) }).value else {
                    updateCollectionProgress { $0.detailFinished(id, successful: false) }; continue
                }
                if source.detailAt != nil { updateCollectionProgress { $0.detailFinished(id, successful: true) }; continue }
                updateCollectionProgress { $0.beginAttempt() }
                do {
                    source = try await client.detail(source)
                    if source.fields["roadAddress", default: ""].isEmpty, KakaoRouteStore.shared.settings.mapFreeConfirmed, !KakaoRouteStore.shared.settings.key.isEmpty {
                        do { if let road = try await KakaoRouteStore.shared.roadAddress(for: source) { source.fields["roadAddress"] = road; source.issues.removeAll { $0.contains("도로명주소") } } }
                        catch is CancellationError { throw CancellationError() }
                        catch { source.issues.append("주소 변환: " + error.localizedDescription) }
                    }
                    consecutiveFailures = 0
                } catch is CancellationError { throw CancellationError() }
                catch let error as RealtyCollectionInterruption { throw error }
                catch { source.issues = [error.localizedDescription]; consecutiveFailures += 1 }
                try Task.checkCancellation()
                let changes = edits, updated = source, revision = editsRevision
                let saved = try await Task.detached(priority: .utility) { try disk.save(updated, edits: changes) }.value
                if editsRevision != revision {
                    let latest = edits
                    try await Task.detached(priority: .utility) { try disk.flush(code, reindex: true, edits: latest) }.value
                }
                pendingSummaries[code] = saved.0
                updateCollectionProgress { $0.detailFinished(id, successful: saved.1.detailAt != nil) }
                if (number + 1) % 10 == 0 { try await Task.detached(priority: .utility) { try disk.flush(code) }.value }
                await refreshCollectedUI()
                updateCollectionProgress { $0.recordAttempt() }
                if consecutiveFailures >= 3 { throw RealtyCollectionInterruption(reason: "상세 응답 오류가 반복되어 수집을 보류했습니다. 자료 형식과 연결 상태를 확인한 뒤 이어서 수집하세요.") }
            }
            try await Task.detached(priority: .utility) { try disk.flush(code) }.value
        } catch {
            try? await Task.detached(priority: .utility) { try disk.flush(code) }.value
            ready.insert(code); await refreshCollectedUI(force: true); throw error
        }
        let final = try await Task.detached(priority: .utility) { try disk.read(code) }.value
        let completed = Set(final.records.filter { $0.detailAt != nil }.map(\.id))
        updateCollectionProgress { value in
            for id in missingIDs where completed.contains(id) { value.detailFinished(id, successful: true) }
        }
        ready.insert(code); await refreshCollectedUI(force: collectionRunID == nil)
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
        edits = next; editsRevision += 1
        // Source corrections update search text; grouping stays explicitly chosen.
        for summary in regions where codes.contains(summary.code) { try collectionDisk?.flush(summary.code, reindex: true, edits: edits) }
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
        guard writable, let disk = collectionDisk else { throw DeviceShareError.unavailable }
        if syncFolderIdentity != folder.absoluteString { published.removeAll(); ready.formUnion(regions.map(\.code)); syncFolderIdentity = folder.absoluteString }
        let current = Dictionary(regions.map { ($0.code, $0.generation) }, uniquingKeysWith: max)
        let incoming = try await Task.detached(priority: .utility) { try HousingFolderIO.read(folder, current: current) }.value
        for name in incoming {
            let region = try await Task.detached(priority: .utility) { try HousingFolderIO.readFile(name, folder: folder) }.value
            _ = try await importCollectedRegion(region)
        }
        for summary in regions where ready.contains(summary.code) {
            let snapshot = try await Task.detached(priority: .utility) { () -> (HousingRegion, Data) in
                let region = try disk.read(summary.code); return (region, try DeviceShareCodec.encode(region))
            }.value
            let data = snapshot.1, generation = snapshot.0.generation
            let key = summary.code + "-" + String(Int(generation)) + "-" + DeviceShareCodec.digest(data).prefix(12)
            guard !published.contains(key) else { continue }
            try await Task.detached(priority: .utility) { try HousingFolderIO.write([(key, data)], folder: folder) }.value
            published.insert(key)
            if (try disk.index.summary(summary.code))?.generation == generation { ready.remove(summary.code) }
        }
        await refreshCollectedUI()
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
