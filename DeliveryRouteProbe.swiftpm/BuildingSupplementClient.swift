import Foundation

enum BuildingSupplementClient {
    static func source(_ source: HousingSource) -> BuildingComplexSource {
        BuildingComplexSource(id:source.isKapt ? source.aptCode : source.id,name:source.fields["name",default:""],
            roadAddresses:BuildingAddress.split(source.fields["roadAddress",default:""]),jibunAddress:source.fields["jibunAddress",default:""],
            fields:source.fields,fetchedAt:source.detailAt ?? Date(),isKapt:source.isKapt)
    }
    @MainActor static func kapt(roadAddress: String, regions: [String], knownCodes: [String] = [], jibunAddresses: [String] = [], cached: [BuildingComplexSource] = [], api: PublicDataStore) async throws -> [BuildingComplexSource] {
        var codes = Set(knownCodes), matching: [BuildingComplexSource] = []
        let requested = BuildingAddress.key(roadAddress)
        for region in Set(regions).sorted() {
            var total: Int?, seen = 0
            for page in 1...1000 {
                try Task.checkCancellation()
                let result = try KaptHousingClient.list(await api.kaptData(.list,parameters:["bjdCode":region,"pageNo":String(page)]),region:region,page:page)
                guard total == nil || total == result.total else { throw BuildingEvaluationError.message("K-apt 보충 목록이 변경되었습니다.") }
                total = result.total; seen += result.records.count; codes.formUnion(result.records.map(\.aptCode))
                if seen == total { break }
            }
            guard seen == total else { throw BuildingEvaluationError.message("K-apt 보충 목록 확인이 완료되지 않았습니다.") }
        }
        var basics: [String:(Data,[String:Any])] = [:]
        let cache = Dictionary(cached.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        codes.formUnion(cache.keys)
        for code in codes.sorted() where cache[code] == nil {
            try Task.checkCancellation()
            let basicData = try await api.kaptData(.basic,parameters:["kaptCode":code])
            let basic = try KaptHousingClient.info(basicData,code:code)
            basics[code] = (basicData,basic)
        }
        var roads = Set([requested].compactMap { $0 }), selected = Set<String>()
        let parcels = Set(jibunAddresses.map(BuildingComplexReview.parcelKey).filter { !$0.isEmpty })
        var changed = true
        while changed {
            changed = false
            for code in codes where !selected.contains(code) {
                let otherRoads = Set((cache[code]?.roadAddresses ?? BuildingAddress.split(KaptGateway.text(basics[code]?.1 ?? [:],"doroJuso"))).compactMap(BuildingAddress.key))
                let parcel = BuildingComplexReview.parcelKey(cache[code]?.jibunAddress ?? KaptGateway.text(basics[code]?.1 ?? [:],"kaptAddr"))
                // A shared parcel expands the comparison set, never membership.
                // Keep the old registration even when its road address is blank.
                if !otherRoads.isDisjoint(with:roads) || (!parcel.isEmpty && parcels.contains(parcel)) {
                    selected.insert(code); roads.formUnion(otherRoads); changed = true
                }
            }
        }
        for code in selected.sorted() {
            try Task.checkCancellation()
            if let source = cache[code] { matching.append(source); continue }
            let entry = basics[code]!, basicData = entry.0
            let facility = try await api.kaptData(.facilities,parameters:["kaptCode":code])
            let raw = HousingSource(id:"kapt:" + (regions.first ?? "") + ":" + code,aptCode:code,noticeDate:"",regionCode:regions.first ?? "",fields:[:])
            matching.append(Self.source(try KaptHousingClient.detail(basic:basicData,facilities:facility,source:raw)))
        }
        return matching
    }
}
