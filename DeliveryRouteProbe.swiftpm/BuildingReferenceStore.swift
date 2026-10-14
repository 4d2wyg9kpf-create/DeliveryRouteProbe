import Foundation
import Combine

struct BuildingReferenceArchive: Codable {
    var version = 1
    var listTotal: Int?
    var nextPage = 1
    var listComplete = false
    var records: [KaptReferenceRecord] = []
    var complexReviews: [BuildingComplexReview]? = nil
    var concordance: KaptConcordance? = nil
    func validate() throws {
        guard version == 1, (1...1001).contains(nextPage), records.count <= 100_000,
              listTotal.map({ (0...100_000).contains($0) }) ?? true,
              Set(records.map(\.id)).count == records.count,
              !listComplete || records.count == listTotal,
              records.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 40 && $0.name.utf8.count <= 500 && $0.roadAddresses.count <= 100 && $0.roadAddresses.allSatisfy { $0.utf8.count <= 2000 } && $0.fields.count <= 100 && $0.fields.values.allSatisfy { $0.utf8.count <= 20_000 } }) else { throw DeviceShareError.invalid }
        try concordance?.validate()
        let recordIDs = Set(records.map(\.id))
        guard (concordance?.reviews ?? []).allSatisfy({ recordIDs.contains($0.kaptID) }),
              records.allSatisfy({ ($0.rawBasic?.count ?? 0) <= 1_000_000 && ($0.rawFacilities?.count ?? 0) <= 1_000_000 }) else { throw DeviceShareError.invalid }
        let reviews = complexReviews ?? []
        guard reviews.count <= 100_000, Set(reviews.map(\.id)).count == reviews.count,
              reviews.reduce(0,{ $0 + $1.buildings.count }) <= 1_000_000 else { throw DeviceShareError.invalid }
        for review in reviews { try review.validate() }
    }
    static func merge(_ a: Self, _ b: Self) throws -> Self {
        try a.validate(); try b.validate()
        guard a.listTotal == nil || b.listTotal == nil || a.listTotal == b.listTotal else { throw BuildingEvaluationError.message("서로 다른 전국 K-apt 목록을 자동으로 합치지 않았습니다.") }
        let larger = a.records.count >= b.records.count ? a : b
        let smaller = a.records.count >= b.records.count ? b : a
        guard larger.records.prefix(smaller.records.count).map(\.id) == smaller.records.map(\.id) else { throw BuildingEvaluationError.message("K-apt 목록 순서가 달라 기존 원본을 보존했습니다.") }
        var next = larger
        let alternatives = Dictionary(smaller.records.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        for index in next.records.indices {
            guard let other = alternatives[next.records[index].id], let otherDate = other.fetchedAt else { continue }
            let existing = next.records[index]
            if existing.fetchedAt == nil || otherDate > existing.fetchedAt! || (otherDate == existing.fetchedAt && (other.facilitiesAt ?? .distantPast) > (existing.facilitiesAt ?? .distantPast)) { next.records[index] = other }
            // Basic and facility checkpoints are independent. Prefer completed
            // facilities only when both devices observed the same basic scope.
            if existing.basicFootprint == other.basicFootprint,
               let facilities = other.facilitiesAt, facilities > (next.records[index].facilitiesAt ?? .distantPast) {
                next.records[index].fields = other.fields
                next.records[index].facilitiesAt = facilities; next.records[index].rawFacilities = other.rawFacilities
            }
            if next.records[index].basicSchemaVersion == nil, other.basicSchemaVersion != nil, existing.fetchedAt == other.fetchedAt { next.records[index] = other }
        }
        next.listComplete = a.listComplete || b.listComplete; next.listTotal = a.listTotal ?? b.listTotal
        next.nextPage = max(a.nextPage,b.nextPage)
        var reviews = Dictionary((a.complexReviews ?? []).map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        for review in b.complexReviews ?? [] {
            reviews[review.id] = try reviews[review.id].map { try BuildingComplexReview.merge($0,review) } ?? review
        }
        next.complexReviews = reviews.values.sorted { $0.id < $1.id }
        next.concordance = try KaptConcordance.merge(a.concordance ?? KaptConcordance(),b.concordance ?? KaptConcordance())
        try next.validate(); return next
    }
}

@MainActor final class BuildingReferenceStore: ObservableObject {
    static let shared = BuildingReferenceStore()
    @Published private(set) var archive = BuildingReferenceArchive()
    @Published private(set) var catalog = KaptReferenceCatalog(addresses: [], missingAddressIDs: [], unresolvedIDs: [], duplicateAddressCount: 0)
    @Published private(set) var managedComplexes: [String:ManagedBuildingComplex] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var progress = ""
    @Published var errorMessage: String?
    private let readState: () throws -> Data?
    private let writeState: (Data) throws -> Void
    private var writable = true
    private var task: Task<Void,Never>?
    private var runID: UUID?
    let collectionStatus = HousingCollectionStatus()
    private var snapshotData: Data?
    private var revision = 0
    private var reviewsByCode: [String:KaptLinkReview] = [:]
    private var pricesByID: [String:HousingSource] = [:]
    private var searchesByRoad: [String:KaptPriceSearch] = [:]
    private var recordsByCode: [String:KaptReferenceRecord] = [:]
    private var decisionsByCode: [String:KaptLinkDecision] = [:]
    private var metadataDurations: [String:TimeInterval] = [:]
    private var detailedPriceIDs = Set<String>()
    private var observationsByRoad: [String:KaptRegistryObservation] = [:]
    private func detailedPrice(_ id: String) -> Bool { pricesByID[id].map { $0.detailAt != nil && ($0.latestNoticeDate == nil || $0.latestNoticeDate == $0.noticeDate) } ?? false }
    private func rebuildIndexes() {
        reviewsByCode = Dictionary(concordance.reviews.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        pricesByID = Dictionary(concordance.sources.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        searchesByRoad = Dictionary(concordance.searches.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        recordsByCode = Dictionary(archive.records.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        decisionsByCode = [:]
        let priceKeys = Dictionary(pricesByID.map { ($0.key,KaptConcordance.sourceKey($0.value)) },uniquingKeysWith:{ x,_ in x })
        for record in archive.records {
            guard let value = reviewsByCode[record.id]?.decision, !record.hasConfirmedBlankRoad,
                  value.kaptScopeKey == record.source.scopeKey,
                  value.realtyIDs.allSatisfy({ detailedPrice($0) && value.realtyScopeKeys[$0] == priceKeys[$0] }) else { continue }
            decisionsByCode[record.id] = value
        }
        detailedPriceIDs = Set(concordance.sources.filter { $0.detailAt != nil && ($0.latestNoticeDate == nil || $0.latestNoticeDate == $0.noticeDate) }.map(\.id))
        observationsByRoad = Dictionary((concordance.observations ?? []).map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
    }
    convenience init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("RouteProbe")
        let file = folder.appendingPathComponent("kapt-reference-catalog.json")
        self.init(read: { FileManager.default.fileExists(atPath:file.path) ? try Data(contentsOf:file) : nil },write: { data in
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try data.write(to:file,options:.atomic)
        })
    }
    init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
        readState = read; writeState = write
        do {
            if let data = try read() {
                guard data.count <= 250_000_000 else { throw DeviceShareError.invalid }
                let value = try JSONDecoder().decode(BuildingReferenceArchive.self,from:data); try value.validate()
                archive = value; catalog = try KaptReferenceCatalog.build(value.records); managedComplexes = BuildingComplexReview.sharedComplexes(value.complexReviews ?? []); snapshotData = data
            }
        } catch { writable = false; errorMessage = "K-apt 표준지 원본 보관함을 보존했습니다. " + error.localizedDescription }
        rebuildIndexes()
    }
    private func commit(_ value: BuildingReferenceArchive) throws {
        guard writable else { throw DeviceShareError.unavailable }
        let value = try BuildingReferenceArchive.merge(archive,value)
        let data = try DeviceShareCodec.encode(value)
        guard data.count <= 250_000_000 else { throw BuildingEvaluationError.message("K-apt 표준지 보관함 크기를 확인하세요.") }
        let result = try KaptReferenceCatalog.build(value.records)
        let complexes = BuildingComplexReview.sharedComplexes(value.complexReviews ?? [])
        try writeState(data); archive = value; catalog = result; managedComplexes = complexes; snapshotData = data; revision += 1; rebuildIndexes()
    }
    private func commitAsync(_ incoming: BuildingReferenceArchive) async throws {
        guard writable else { throw DeviceShareError.unavailable }
        while true {
            let before = archive, previousRevision = revision
            let prepared = try await Task.detached(priority:.utility) {
                let value = try BuildingReferenceArchive.merge(before,incoming)
                let data = try DeviceShareCodec.encode(value)
                guard data.count <= 250_000_000 else { throw BuildingEvaluationError.message("K-apt 보관함 크기를 확인하세요.") }
                let catalog = try KaptReferenceCatalog.build(value.records)
                return (value,data,catalog)
            }.value
            // A review made during encoding is merged before the checkpoint.
            guard previousRevision == revision else { continue }
            try writeState(prepared.1); archive = prepared.0; snapshotData = prepared.1; catalog = prepared.2
            managedComplexes = BuildingComplexReview.sharedComplexes(prepared.0.complexReviews ?? [])
            revision += 1; rebuildIndexes(); return
        }
    }
    func stop() {
        task?.cancel()
        if task == nil, let id = runID {
            HousingCollectionBackground.shared.finish(id:id,success:false)
            runID = nil; isBusy = false; HousingStore.shared.isBusy = false
        }
    }
    func start(api: PublicDataStore, codes: Set<String>? = nil, refresh: Bool = false, extraRoad: String? = nil) {
        guard !isBusy else { return }
        guard !HousingStore.shared.isBusy else { errorMessage = "다른 공동주택 수집이 진행 중입니다."; return }
        let id = UUID(); runID = id
        isBusy = true; errorMessage = nil; HousingStore.shared.isBusy = true; metadataDurations = [:]
        var value = HousingCollectionProgress(scopeTitle:"K-apt 단지·공시가격 연결 수집",includesDetails:true)
        value.setTargets(["kapt-reference"]); value.beginRegion(id:"kapt-reference",title:"K-apt 단지·공시가격 연결 수집")
        collectionStatus.value = value
        HousingCollectionBackground.shared.begin(id:id,title:"K-apt 단지·공시가격 연결 수집",status:collectionStatus,start:{ [weak self] in
            guard let self, self.runID == id else { return }; self.beginWork(api:api,id:id,codes:codes,refresh:refresh,extraRoad:extraRoad)
        },expire:{ [weak self] in
            self?.collectionStatus.backgroundMessage = "시스템이 수집을 중단했습니다. 저장한 목록에서 이어서 진행할 수 있습니다."
            self?.stop()
        })
    }
    private func beginWork(api: PublicDataStore, id: UUID, codes: Set<String>?, refresh: Bool, extraRoad: String?) {
        task = Task {
            var success = false
            defer {
                HousingCollectionBackground.shared.finish(id:id,success:success)
                isBusy = false; task = nil; runID = nil; HousingStore.shared.isBusy = false; try? DeviceShareHooks.changed()
            }
            do {
                let client = RealtyAddressSearchClient()
                if let extraRoad {
                    try await collectExtraAddress(extraRoad,client:client)
                } else {
                    // Resolve the K-apt inventory once, then alternate metadata
                    // and address searches in small saved batches. Completed
                    // complexes share one monotonic overall progress counter.
                    try await collect(api:api,codes:[],markCompleted:false,configureProgress:false)
                    let targets = archive.records.filter { codes == nil || codes!.contains($0.id) }
                    if var value = collectionStatus.value {
                        let completed = Set(targets.filter { !refresh && collectionComplete($0) }.map(\.id))
                        value.recordInventory(regionID:"kapt-reference",ids:targets.map(\.id),completedIDs:completed)
                        value.sealInventory(); value.beginDetails(ids:targets.filter { !completed.contains($0.id) }.map(\.id),previouslyCompleted:completed.count)
                        collectionStatus.value = value; updateBackground()
                    }
                    for offset in stride(from:0,to:targets.count,by:25) {
                        let batch = Set(targets[offset..<min(targets.count,offset+25)].map(\.id))
                        try await collect(api:api,codes:batch,refresh:refresh,markCompleted:false,configureProgress:false)
                        try await collectPrices(codes:batch,refresh:refresh,search:{ road in
                            try await client.search(road,addresses:{ try await HousingStore.shared.buildingAddresses($0) })
                        },detail:{ try await client.client.detail($0) })
                    }
                }
                progress = "수집했습니다. K-apt 단지별 연결을 확인하고 승인하세요."; success = true; collectionStatus.value?.finish()
            }
            catch is CancellationError { progress = "중단했습니다. 완료된 자료에서 이어서 수집합니다."; collectionStatus.value?.stop() }
            catch { errorMessage = error.localizedDescription; progress = "미완료 자료는 이어서 수집할 수 있습니다."; collectionStatus.value?.fail() }
        }
    }
    private func updateBackground() {
        guard let id = runID, let value = collectionStatus.value else { return }
        HousingCollectionBackground.shared.update(id:id,progress:value)
    }
    func collect(api: PublicDataStore, codes: Set<String>? = nil, refresh: Bool = false, markCompleted: Bool = true, configureProgress: Bool = true) async throws {
        var next = archive
        while !next.listComplete {
            try Task.checkCancellation()
            progress = "전국 K-apt 단지 목록 · \(next.records.count)/\(next.listTotal.map(String.init) ?? "?")"
            let data = try await api.kaptData(.all,parameters:["pageNo":String(next.nextPage)])
            let body = try KaptGateway.body(data)
            guard let total = Int(KaptGateway.text(body,"totalCount")), (0...100_000).contains(total),
                  Int(KaptGateway.text(body,"pageNo")) == next.nextPage,
                  next.listTotal == nil || next.listTotal == total else { throw BuildingEvaluationError.message("전국 K-apt 목록 건수가 바뀌었습니다. 원본을 보존하고 수집을 보류합니다.") }
            let raw = (body["items"] as? [String:Any])?["item"] ?? body["items"]
            let rows = raw as? [[String:Any]] ?? (raw as? [String:Any]).map { [$0] } ?? []
            guard rows.count == min(100,max(0,total-(next.nextPage-1)*100)) else { throw BuildingEvaluationError.message("전국 K-apt 목록 페이지가 누락되었습니다.") }
            let records = try rows.map { row -> KaptReferenceRecord in
                let code = KaptGateway.text(row,"kaptCode"), name = KaptGateway.text(row,"kaptName")
                guard code.range(of:#"^[A-Za-z0-9]{1,40}$"#,options:.regularExpression) != nil, !name.isEmpty else { throw DeviceShareError.invalid }
                return KaptReferenceRecord(id:code,name:name,roadAddresses:[])
            }
            guard Set(next.records.map(\.id)).isDisjoint(with:Set(records.map(\.id))), Set(records.map(\.id)).count == records.count else { throw BuildingEvaluationError.message("전국 K-apt 목록의 단지 코드가 중복되어 완료 처리하지 않았습니다.") }
            next.records.append(contentsOf:records); next.listTotal = total; next.nextPage += 1
            next.listComplete = next.records.count == total; try commit(next); next = archive
        }
        let targets = next.records.filter { codes == nil || codes!.contains($0.id) }
        if configureProgress, var value = collectionStatus.value {
            let completedIDs = Set(targets.filter { markCompleted ? ($0.hasConfirmedBlankRoad || $0.facilitiesAt != nil) : collectionComplete($0) }.map(\.id))
            value.recordInventory(regionID:"kapt-reference",ids:targets.map(\.id),completedIDs:completedIDs)
            value.sealInventory(); value.beginDetails(ids:targets.filter { !completedIDs.contains($0.id) }.map(\.id),previouslyCompleted:completedIDs.count)
            collectionStatus.value = value; updateBackground()
        }
        var dirty = false, completed = 0
        defer { if dirty { try? commit(next) } }
        for index in next.records.indices {
            try Task.checkCancellation()
            let record = next.records[index]
            guard codes == nil || codes!.contains(record.id) else { continue }
            if !refresh && isExcluded(record) { continue }
            guard refresh || record.fetchedAt == nil || record.basicSchemaVersion != 2 || (!record.hasConfirmedBlankRoad && record.facilitiesAt == nil) else { continue }
            let started = Date(); collectionStatus.value?.beginAttempt()
            progress = "K-apt 기본·관리 정보 · " + record.name
            if refresh || record.fetchedAt == nil || record.basicSchemaVersion != 2 {
                let data = try await api.kaptData(.basic,parameters:["kaptCode":record.id])
                guard data.count <= 1_000_000 else { throw DeviceShareError.invalid }
                let basic = try KaptHousingClient.info(data,code:record.id)
                next.records[index].name = KaptGateway.text(basic,"kaptName").isEmpty ? record.name : KaptGateway.text(basic,"kaptName")
                next.records[index].roadAddresses = [KaptGateway.text(basic,"doroJuso")]
                var fields: [String:String] = [:]
                for (name,key) in ["approvalDate":"kaptUsedate","households":"kaptdaCnt","buildings":"kaptDongCnt","heating":"codeHeatNm","corridor":"codeHallNm","saleType":"codeSaleNm","managementOffice":"kaptTel","jibunAddress":"kaptAddr","use":"codeAptNm"] { fields[name] = KaptGateway.text(basic,key) }
                if let date = PublicDataParser.date(fields["approvalDate",default:""]) { fields["approvalDate"] = date }
                next.records[index].fields = fields; next.records[index].rawBasic = data
                next.records[index].fetchedAt = Date(); next.records[index].basicSchemaVersion = 2
                next.records[index].facilitiesAt = nil; next.records[index].rawFacilities = nil; dirty = true
            }
            let updated = next.records[index]
            // An actually fetched blank road address is skipped. An unfetched
            // list row is never mistaken for a demolished registration.
            if !updated.hasConfirmedBlankRoad && (refresh || updated.facilitiesAt == nil) {
                guard let basicData = updated.rawBasic else { throw DeviceShareError.invalid }
                let facilities = try await api.kaptData(.facilities,parameters:["kaptCode":record.id])
                guard facilities.count <= 1_000_000 else { throw DeviceShareError.invalid }
                let raw = HousingSource(id:"kapt:reference:" + record.id,aptCode:record.id,noticeDate:"",regionCode:"",fields:[:])
                let source = try KaptHousingClient.detail(basic:basicData,facilities:facilities,source:raw)
                next.records[index].fields = source.fields
                next.records[index].facilitiesAt = Date(); next.records[index].rawFacilities = facilities; dirty = true
            }
            completed += 1
            metadataDurations[record.id] = Date().timeIntervalSince(started)
            if markCompleted { collectionStatus.value?.recordAttempt() }
            if markCompleted || next.records[index].hasConfirmedBlankRoad { collectionStatus.value?.detailFinished(record.id,successful:true) }
            updateBackground()
            if completed % 10 == 0 { try await commitAsync(next); next = archive; dirty = false; await Task.yield() }
        }
        if dirty { try await commitAsync(next); dirty = false }
        try DeviceShareHooks.changed()
    }
    func collectPrices(codes: Set<String>? = nil, refresh: Bool = false,
        search: (String) async throws -> (KaptPriceSearch,[HousingSource]),
        detail: (HousingSource) async throws -> HousingSource) async throws {
        let targets = archive.records.filter { codes == nil || codes!.contains($0.id) }
        var searched = Set<String>(), count = 0, next = archive, dirty = false
        var local = concordance
        var prices = pricesByID, jobs = searchesByRoad
        func checkpointValue() -> BuildingReferenceArchive { var value = next; value.concordance = local; return value }
        do {
            for record in targets {
                try Task.checkCancellation()
                count += 1; progress = "공시가격 주소 대조 · " + record.name
                if isExcluded(record) && !refresh || record.hasConfirmedBlankRoad {
                    collectionStatus.value?.detailFinished(record.id,successful:true); updateBackground(); continue
                }
                guard record.fetchedAt != nil, !record.roads.isEmpty, record.roadAddresses.filter({ !BuildingFacts.blank($0) }).allSatisfy(BuildingAddress.allPartsValid) else {
                    throw BuildingEvaluationError.message(record.name + ": 도로명주소가 미확인입니다. 원본 주소를 확인하세요.")
                }
                let timed = refresh || !collectionComplete(record)
                if timed { collectionStatus.value?.beginAttempt(at:Date().addingTimeInterval(-(metadataDurations[record.id] ?? 0))) }
                for road in record.roads {
                    let key = BuildingAddress.key(road)!
                    if jobs[key] == nil || (refresh && !searched.contains(key)) {
                        let (job,sources) = try await search(road)
                        guard job.id == key, Set(job.sourceIDs) == Set(sources.map(\.id)) else { throw DeviceShareError.invalid }
                        try job.validate()
                        jobs[key] = job
                        for source in sources {
                            if var prior = prices[source.id], prior.detailAt != nil {
                                let newest = max(prior.latestNoticeDate ?? prior.noticeDate,source.latestNoticeDate ?? source.noticeDate)
                                if newest > prior.noticeDate { prior.latestNoticeDate = newest }
                                prices[source.id] = prior
                            } else { prices[source.id] = source }
                        }
                        searched.insert(key); dirty = true
                    }
                    for id in jobs[key]!.sourceIDs {
                        guard let source = prices[id] else { throw DeviceShareError.invalid }
                        guard source.detailAt == nil || (source.latestNoticeDate != nil && source.latestNoticeDate != source.noticeDate) || (refresh && !searched.contains("detail:" + id)) else { continue }
                        let updated = try await detail(source)
                        guard updated.id == id, updated.detailAt != nil else { throw DeviceShareError.invalid }
                        prices[id] = updated; searched.insert("detail:" + id); dirty = true
                    }
                }
                if timed { collectionStatus.value?.recordAttempt() }
                collectionStatus.value?.detailFinished(record.id,successful:true); updateBackground()
                if count % 10 == 0, dirty {
                    local.sources = prices.values.sorted { $0.id < $1.id }; local.searches = jobs.values.sorted { $0.id < $1.id }
                    try await commitAsync(checkpointValue()); next = archive; local = concordance
                    prices = pricesByID; jobs = searchesByRoad; dirty = false
                }
                await Task.yield()
            }
            if dirty {
                local.sources = prices.values.sorted { $0.id < $1.id }; local.searches = jobs.values.sorted { $0.id < $1.id }
                try await commitAsync(checkpointValue()); dirty = false
            }
        } catch {
            if dirty {
                local.sources = prices.values.sorted { $0.id < $1.id }; local.searches = jobs.values.sorted { $0.id < $1.id }
                try await commitAsync(checkpointValue())
            }
            throw error
        }
        try DeviceShareHooks.changed()
    }
    private func collectExtraAddress(_ road: String, client: RealtyAddressSearchClient) async throws {
        guard let key = BuildingAddress.key(road) else { throw BuildingEvaluationError.message("정확한 도로명주소를 입력하세요.") }
        progress = "추가 공시가격 주소 검색 · " + road
        let (job,sources) = try await client.search(road,addresses:{ try await HousingStore.shared.buildingAddresses($0) })
        var next = archive
        next.concordance = try KaptConcordance.merge(concordance,KaptConcordance(searches:[job],sources:sources))
        try await commitAsync(next)
        for id in job.sourceIDs {
            try Task.checkCancellation()
            guard let source = pricesByID[id] else { throw DeviceShareError.invalid }
            if !detailedPrice(id) { try mergeConcordance(KaptConcordance(sources:[try await client.client.detail(source)])) }
        }
        progress = "추가 주소 후보 \(job.sourceIDs.count)개 · " + key
    }
    var concordance: KaptConcordance { archive.concordance ?? KaptConcordance() }
    func mergeConcordance(_ delta: KaptConcordance) throws {
        var next = archive; next.concordance = try KaptConcordance.merge(concordance,delta); try commit(next)
    }
    func linkReview(_ code: String) -> KaptLinkReview? { reviewsByCode[code] }
    func currentDecision(_ record: KaptReferenceRecord) -> KaptLinkDecision? {
        guard let known = recordsByCode[record.id], known.fetchedAt == record.fetchedAt,
              known.facilitiesAt == record.facilitiesAt, known.name == record.name,
              known.roadAddresses == record.roadAddresses, known.fields == record.fields else { return nil }
        return decisionsByCode[record.id]
    }
    func isExcluded(_ record: KaptReferenceRecord) -> Bool { record.hasConfirmedBlankRoad || currentDecision(record)?.disposition == .excluded }
    func collectionComplete(_ record: KaptReferenceRecord) -> Bool {
        if isExcluded(record) { return true }
        guard record.fetchedAt != nil, record.facilitiesAt != nil, !record.roads.isEmpty else { return false }
        let searches = searchesByRoad
        let detailed = detailedPriceIDs
        return record.roads.allSatisfy { road in searches[BuildingAddress.key(road)!].map { Set($0.sourceIDs).isSubset(of:detailed) } ?? false }
    }
    var validKaptRecords: [KaptReferenceRecord] { archive.records.filter { decisionsByCode[$0.id]?.disposition == .accepted } }
    var pendingKaptRecords: [KaptReferenceRecord] { archive.records.filter { !$0.hasConfirmedBlankRoad && decisionsByCode[$0.id] == nil } }
    func candidates(_ record: KaptReferenceRecord) -> [HousingSource] {
        let keys = Set(record.roads.compactMap(BuildingAddress.key))
        let searchedIDs = Set(concordance.searches.filter { keys.contains($0.id) }.flatMap(\.sourceIDs))
        let linkedIDs = Set(linkReview(record.id)?.heads.flatMap(\.realtyIDs) ?? [])
        return concordance.sources.filter { searchedIDs.contains($0.id) || linkedIDs.contains($0.id) }.sorted { $0.id < $1.id }
    }
    func saveLink(_ decision: KaptLinkDecision) throws {
        try decision.validate()
        guard let record = archive.records.first(where:{ $0.id == decision.kaptID }), record.fetchedAt != nil,
              decision.kaptScopeKey == record.source.scopeKey, !record.hasConfirmedBlankRoad else { throw BuildingEvaluationError.message("K-apt 원본이 변경되었거나 도로명주소가 공란입니다. 다시 수집·확인하세요.") }
        let sources = pricesByID
        guard decision.realtyIDs.allSatisfy({ id in sources[id].map { detailedPrice(id) && KaptConcordance.sourceKey($0) == decision.realtyScopeKeys[id] } ?? false }) else { throw BuildingEvaluationError.message("연결할 공시가격 상세가 미완료이거나 변경되었습니다. 다시 확인하세요.") }
        if decision.disposition == .accepted {
            guard record.facilitiesAt != nil else { throw BuildingEvaluationError.message("K-apt 관리 정보를 먼저 수집하세요.") }
            let known = Dictionary((concordance.observations ?? []).flatMap(\.buildings).map { ($0.roadKey + "|" + $0.id,$0) },uniquingKeysWith:{ x,_ in x })
            let roadKeys = Set(record.roads.compactMap(BuildingAddress.key))
            guard decision.memberBuildings.allSatisfy({ identity,scope in known[identity].map { $0.complexScopeKey == scope && roadKeys.contains($0.roadKey) } ?? false }) else {
                throw BuildingEvaluationError.message("같은 단지 주소에서 대장으로 확인한 건물만 소속·표준 건물로 선택하세요.")
            }
        }
        try mergeConcordance(KaptConcordance(reviews:[KaptLinkReview(kaptID:record.id,heads:[decision])]))
        try DeviceShareHooks.changed()
    }
    func saveObservation(_ observation: KaptRegistryObservation) throws {
        try mergeConcordance(KaptConcordance(observations:[observation])); try DeviceShareHooks.changed()
    }
    func profiles(_ buildings: [EvaluationBuilding]) -> [String:BuildingComplexProfile] {
        let owners = memberOwners()
        var result: [String:BuildingComplexProfile] = [:]
        let valid = validKaptRecords
        let decisions = Dictionary(valid.compactMap { record in currentDecision(record).map { (record.id,$0) } },uniquingKeysWith:{ x,_ in x })
        var priceOwners: [String:Set<String>] = [:]
        for decision in decisions.values { for id in decision.realtyIDs { priceOwners[id,default:[]].insert(decision.kaptID) } }
        let records = Dictionary(valid.map { ($0.id,$0) },uniquingKeysWith:{ x,_ in x })
        for building in buildings {
            let identity = building.roadKey + "|" + building.id
            guard let codes = owners[identity], codes.count == 1, let code = codes.first,
                  let record = records[code], let decision = decisions[code],
                  decision.memberBuildings[identity] == building.complexScopeKey,
                  let observation = observationsByRoad[building.roadKey],
                  observation.buildings.contains(where:{ $0.id == building.id && $0.complexScopeKey == building.complexScopeKey }) else { continue }
            let complexID = "kapt:" + code
            let linked = decision.realtyIDs.compactMap { pricesByID[$0] }
            let whole = linked.filter { decision.realtyIDs.count == 1 && decision.wholeRealtyIDs.contains($0.id) && priceOwners[$0.id] == [code] }
            var registry: [String:String] = [:]
            if let parent = building.parentRegistryID, let group = observation.groups.first(where:{ $0.id == parent }),
               BuildingComplexReview.matches(record.source,group),
               valid.filter({ BuildingComplexReview.matches($0.source,group) }).map(\.id) == [code] {
                registry = group.fields
            }
            let priceFields = BuildingFacts.consensus(whole.map(\.fields))
            var shared: [String:BuildingFact] = [:]
            for (source,fields) in [(BuildingFactSource.registry,registry),(.realty,priceFields),(.kapt,record.fields)] {
                for (field,value) in fields where !BuildingFacts.blank(value) && (BuildingComplexReview.sharedKeys.contains(field) || ["households","buildings"].contains(field)) {
                    let key = field == "households" ? "complexHouseholds" : field == "buildings" ? "complexBuildings" : field
                    if shared[key] == nil { shared[key] = BuildingFact(value:value,source:source,scope:.complex,complexID:complexID) }
                }
            }
            if let parking = Double(shared["parking"]?.value ?? ""), let households = Double(shared["complexHouseholds"]?.value ?? ""), parking.isFinite, households.isFinite, parking >= 0, households > 0 {
                shared["parkingPerHousehold"] = BuildingFact(value:String(format:"%.4f",parking/households),source:shared["parking"]!.source,scope:.complex,complexID:complexID)
            }
            let eligiblePrices = linked.filter { source in
                if whole.contains(where:{ $0.id == source.id }) { return true }
                let dong = BuildingAddress.dongKey(building.dongName)
                let labels = HousingIdentity.dongLabels(source).map(BuildingAddress.dongKey)
                return !dong.isEmpty && labels.contains(dong) && observation.buildings.filter { BuildingAddress.dongKey($0.dongName) == dong }.count == 1
            }.map { source -> [String:String] in
                if whole.contains(where:{ $0.id == source.id }) { return source.fields }
                return source.fields.filter { !BuildingComplexReview.sharedKeys.contains($0.key) && !["households","buildings"].contains($0.key) }
            }
            var facts = BuildingFacts.resolve(registry:building.fields,realty:BuildingFacts.consensus(eligiblePrices),kapt:record.fields,apartment:building.fields["use",default:""].contains("아파트"))
            facts = facts.filter { $0.value.scope == .building || !BuildingComplexReview.sharedKeys.contains($0.key) }
            for key in facts.keys where facts[key]?.scope == .complex { facts[key]?.complexID = complexID }
            let complex = ManagedBuildingComplex(id:complexID,name:record.name,kaptIDs:[code],adoptedKaptID:code,sharedFacts:shared,reason:decision.reason,reviewedAt:decision.updatedAt,dataCheckedAt:record.facilitiesAt ?? record.fetchedAt)
            let binding = BuildingComplexBinding(complexID:complexID,buildingScopeKey:building.complexScopeKey,registryParentID:building.parentRegistryID,reviewID:decision.id)
            result[identity] = BuildingComplexProfile(binding:binding,complex:complex,facts:facts)
        }
        return result
    }
    func profile(_ building: EvaluationBuilding) -> BuildingComplexProfile? { profiles([building])[building.roadKey + "|" + building.id] }
    var complexReviews: [BuildingComplexReview] { archive.complexReviews ?? [] }
    var standardAddresses: [KaptReferenceAddress] {
        let excluded = BuildingComplexReview.excludedCodes(complexReviews)
        return catalog.addresses.filter { !Set($0.kaptIDs).isSubset(of:excluded) }
    }
    func connectedKaptCodes(_ roadAddress: String) -> [String] {
        guard let key = BuildingAddress.key(roadAddress) else { return [] }
        var byRoad: [String:Set<String>] = [:], byCode: [String:Set<String>] = [:]
        for address in catalog.addresses {
            byRoad[address.id] = Set(address.kaptIDs)
            for code in address.kaptIDs { byCode[code,default:[]].insert(address.id) }
        }
        var roads = [key], visited = Set<String>(), codes = Set<String>(), cursor = 0
        while cursor < roads.count {
            let road = roads[cursor]; cursor += 1
            guard visited.insert(road).inserted else { continue }
            for code in byRoad[road] ?? [] where codes.insert(code).inserted { roads.append(contentsOf:byCode[code] ?? []) }
        }
        return codes.sorted()
    }
    func complexReview(_ roadAddress: String) -> BuildingComplexReview? {
        let key = BuildingAddress.key(roadAddress); return complexReviews.first { $0.id == key }
    }
    func saveComplexReview(_ review: BuildingComplexReview) throws {
        try review.validate()
        var next = archive, values = complexReviews
        if let index = values.firstIndex(where:{ $0.id == review.id }) { values[index] = review }
        else { values.append(review) }
        if review.usable && !review.automatic {
            for index in values.indices where values[index].id != review.id {
                if let updated = values[index].updatingAdoption(from:review) { values[index] = updated }
            }
        }
        next.complexReviews = values; try commit(next); try DeviceShareHooks.changed()
    }
    func standardSites(_ sites: [SiteTarget]) throws -> [SiteTarget] {
        guard archive.listComplete, catalog.complete, !archive.records.isEmpty else {
            throw BuildingEvaluationError.message("전국 K-apt 기본 목록·주소 확인을 먼저 완료하세요. 미수집 등록은 공란으로 제외하지 않습니다.")
        }
        var selected: [SiteTarget] = [], used = Set<String>()
        let membership = memberOwners()
        let resolved = profiles(sites.compactMap { $0.building?.building })
        for record in archive.records {
            if isExcluded(record) { continue }
            guard let decision = currentDecision(record), decision.disposition == .accepted else {
                throw BuildingEvaluationError.message(record.name + ": 연결·유효 여부를 먼저 검증하세요.")
            }
            guard let identity = decision.standardBuildingIdentity,
                  let site = sites.first(where:{ $0.building?.identity == identity }), let building = site.building,
                  decision.memberBuildings[identity] == building.building.complexScopeKey,
                  membership[identity] == [record.id], resolved[identity]?.complex.adoptedKaptID == record.id, used.insert(identity).inserted else {
                throw BuildingEvaluationError.message(record.name + ": 소속·입구를 확인한 표준 건물 하나를 지정하세요. 다른 단지와 같은 건물을 중복 선택하지 않습니다.")
            }
            try building.validate(); selected.append(site)
        }
        guard !selected.isEmpty else { throw BuildingEvaluationError.message("유효한 K-apt 표준 단지가 없습니다.") }
        return selected
    }
    func memberOwners() -> [String:Set<String>] {
        var result: [String:Set<String>] = [:]
        // Unresolved device conflicts also reserve their membership: a second
        // device cannot silently transfer a building into a competing complex.
        for record in archive.records where !record.hasConfirmedBlankRoad {
            guard let review = linkReview(record.id) else { continue }
            let decisions = review.conflicted ? review.heads : currentDecision(record).map { [$0] } ?? []
            for decision in decisions where decision.disposition == .accepted {
                for identity in decision.memberBuildings.keys { result[identity,default:[]].insert(record.id) }
            }
        }
        return result
    }
    var populationToken: String {
        let values = archive.records.sorted { $0.id < $1.id }.map { record -> String in
            let decision = currentDecision(record)
            return BuildingComplexReview.key([record.id,record.source.scopeKey,isExcluded(record) ? "excluded" : "included",
                decision.map { BuildingComplexReview.key([$0.realtyScopeKeys,$0.memberBuildings]) } ?? "pending",
                decision?.standardBuildingIdentity ?? "",linkReview(record.id)?.conflicted == true ? "conflict" : "clear"])
        }
        return DeviceShareCodec.digest(Data(values.joined(separator:"\n").utf8))
    }
    func sharingSnapshot() throws -> DeviceShareSnapshot {
        guard writable else { throw DeviceShareError.unavailable }
        var result = DeviceShareSnapshot(); guard let data = snapshotData else { return result }
        let count = max(1,(data.count+299_999)/300_000)
        result.values["setting/building-reference/header"] = try DeviceShareCodec.encode(BuildingReferenceHeader(parts:count,digest:DeviceShareCodec.digest(data)))
        for part in 0..<count {
            result.values["setting/building-reference/part/\(part)"] = try DeviceShareCodec.encode(data.subdata(in:part*300_000..<min(data.count,(part+1)*300_000)))
        }
        return result
    }
    func applySharing(_ replica: DeviceShareReplica) throws {
        guard let header = try replica.value("setting/building-reference/header",as:BuildingReferenceHeader.self) else { return }
        guard (1...834).contains(header.parts) else { throw DeviceShareError.invalid }
        var data = Data()
        for part in 0..<header.parts {
            guard let bytes = try replica.value("setting/building-reference/part/\(part)",as:Data.self), !bytes.isEmpty, bytes.count <= 300_000 else { throw DeviceShareError.invalid }
            data.append(bytes)
        }
        guard data.count <= 250_000_000, DeviceShareCodec.digest(data) == header.digest else { throw DeviceShareError.invalid }
        if data != snapshotData { try commit(JSONDecoder().decode(BuildingReferenceArchive.self,from:data)) }
    }
}
private struct BuildingReferenceHeader: Codable { var parts: Int; var digest: String }
