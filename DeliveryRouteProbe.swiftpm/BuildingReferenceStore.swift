import Foundation
import Combine

struct BuildingReferenceArchive: Codable {
    var version = 1
    var listTotal: Int?
    var nextPage = 1
    var listComplete = false
    var records: [KaptReferenceRecord] = []
    func validate() throws {
        guard version == 1, (1...1001).contains(nextPage), records.count <= 100_000,
              listTotal.map({ (0...100_000).contains($0) }) ?? true,
              Set(records.map(\.id)).count == records.count,
              !listComplete || records.count == listTotal,
              records.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 40 && $0.name.utf8.count <= 500 && $0.roadAddresses.count <= 100 && $0.roadAddresses.allSatisfy { $0.utf8.count <= 2000 } && $0.fields.count <= 100 && $0.fields.values.allSatisfy { $0.utf8.count <= 20_000 } }) else { throw DeviceShareError.invalid }
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
            if next.records[index].fetchedAt == nil || otherDate > next.records[index].fetchedAt! { next.records[index] = other }
        }
        next.listComplete = a.listComplete || b.listComplete; next.listTotal = a.listTotal ?? b.listTotal
        next.nextPage = max(a.nextPage,b.nextPage); try next.validate(); return next
    }
}

@MainActor final class BuildingReferenceStore: ObservableObject {
    static let shared = BuildingReferenceStore()
    @Published private(set) var archive = BuildingReferenceArchive()
    @Published private(set) var catalog = KaptReferenceCatalog(addresses: [], missingAddressIDs: [], unresolvedIDs: [], duplicateAddressCount: 0)
    @Published private(set) var isBusy = false
    @Published private(set) var progress = ""
    @Published var errorMessage: String?
    private let readState: () throws -> Data?
    private let writeState: (Data) throws -> Void
    private var writable = true
    private var task: Task<Void,Never>?
    private var snapshotData: Data?
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
                guard data.count <= 50_000_000 else { throw DeviceShareError.invalid }
                let value = try JSONDecoder().decode(BuildingReferenceArchive.self,from:data); try value.validate()
                archive = value; catalog = try KaptReferenceCatalog.build(value.records); snapshotData = data
            }
        } catch { writable = false; errorMessage = "K-apt 표준지 원본 보관함을 보존했습니다. " + error.localizedDescription }
    }
    private func commit(_ value: BuildingReferenceArchive) throws {
        guard writable else { throw DeviceShareError.unavailable }
        let value = try BuildingReferenceArchive.merge(archive,value)
        let data = try DeviceShareCodec.encode(value)
        guard data.count <= 50_000_000 else { throw BuildingEvaluationError.message("K-apt 표준지 보관함 크기를 확인하세요.") }
        let result = try KaptReferenceCatalog.build(value.records)
        try writeState(data); archive = value; catalog = result; snapshotData = data
    }
    func stop() { task?.cancel() }
    func start(api: PublicDataStore) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        task = Task {
            defer { isBusy = false; task = nil; try? DeviceShareHooks.changed() }
            do { try await collect(api:api); progress = "전국 K-apt 도로명주소 목록을 확인했습니다." }
            catch is CancellationError { progress = "중단했습니다. 완료된 자료에서 이어서 수집합니다." }
            catch { errorMessage = error.localizedDescription; progress = "미완료 자료는 이어서 수집할 수 있습니다." }
        }
    }
    func collect(api: PublicDataStore) async throws {
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
        var dirty = false, completed = 0
        defer { if dirty { try? commit(next) } }
        for index in next.records.indices where next.records[index].fetchedAt == nil {
            try Task.checkCancellation()
            let record = next.records[index]
            progress = "K-apt 도로명주소 · \(index+1)/\(next.records.count) · \(record.name)"
            let basic = try KaptHousingClient.info(await api.kaptData(.basic,parameters:["kaptCode":record.id]),code:record.id)
            next.records[index].roadAddresses = [KaptGateway.text(basic,"doroJuso")]
            var fields: [String:String] = [:]
            for (name, key) in ["approvalDate":"kaptUsedate", "households":"kaptdaCnt", "buildings":"kaptDongCnt", "heating":"codeHeatNm", "corridor":"codeHallNm", "saleType":"codeSaleNm", "managementOffice":"kaptTel"] { fields[name] = KaptGateway.text(basic,key) }
            if let date = PublicDataParser.date(fields["approvalDate",default:""]) { fields["approvalDate"] = date }
            next.records[index].fields = fields; next.records[index].fetchedAt = Date(); dirty = true; completed += 1
            if completed % 10 == 0 { try commit(next); next = archive; dirty = false }
        }
        if dirty { try commit(next); next = archive; dirty = false }
        guard archive.listComplete, catalog.complete else { throw BuildingEvaluationError.message("전국 주소 확인이 미완료입니다. 형식 미확인 또는 상세 미수집 등록을 확인하세요.") }
        try DeviceShareHooks.changed()
    }
    func supplementalFields(_ roadAddress: String) -> [String:String] {
        guard let key = BuildingAddress.key(roadAddress), let address = catalog.addresses.first(where: { $0.id == key }) else { return [:] }
        let sources = archive.records.filter { address.kaptIDs.contains($0.id) }.sorted { $0.id < $1.id }
        var fields: [String:String] = [:]
        // Retain one value only if all nonblank sources agree. Duplicate K-apt
        // registrations must not silently add counts or overwrite conflicting facts.
        for key in Set(sources.flatMap { $0.fields.keys }) {
            let values = Set(sources.compactMap { BuildingFacts.blank($0.fields[key]) ? nil : $0.fields[key] })
            if values.count == 1 { fields[key] = values.first }
        }
        return fields
    }
    func standardSites(_ sites: [SiteTarget]) throws -> [SiteTarget] {
        guard archive.listComplete, catalog.complete, !catalog.addresses.isEmpty else {
            throw BuildingEvaluationError.message("전국 K-apt 목록과 도로명주소 확인을 먼저 완료하세요. 상세 미수집은 주소 공란으로 제외하지 않습니다.")
        }
        var grouped: [String:[SiteTarget]] = [:]
        for site in sites {
            guard let selection = site.building, selection.isDefaultForAddress else { continue }
            grouped[selection.building.roadKey,default:[]].append(site)
        }
        var result: [SiteTarget] = []
        for address in catalog.addresses {
            guard let targets = grouped[address.id], targets.count == 1 else {
                throw BuildingEvaluationError.message("\(address.roadAddress): 기본 건물의 입구가 미확인되었거나 기본 등록이 중복되었습니다.")
            }
            result.append(targets[0])
        }
        return result
    }
    var populationToken: String {
        DeviceShareCodec.digest(Data(catalog.addresses.map(\.id).joined(separator:"\n").utf8))
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
        guard (1...167).contains(header.parts) else { throw DeviceShareError.invalid }
        var data = Data()
        for part in 0..<header.parts {
            guard let bytes = try replica.value("setting/building-reference/part/\(part)",as:Data.self), !bytes.isEmpty, bytes.count <= 300_000 else { throw DeviceShareError.invalid }
            data.append(bytes)
        }
        guard data.count <= 50_000_000, DeviceShareCodec.digest(data) == header.digest else { throw DeviceShareError.invalid }
        if data != snapshotData { try commit(JSONDecoder().decode(BuildingReferenceArchive.self,from:data)) }
    }
}
private struct BuildingReferenceHeader: Codable { var parts: Int; var digest: String }
