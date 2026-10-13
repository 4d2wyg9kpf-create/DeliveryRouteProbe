import Foundation

enum BuildingSupplementClient {
    @MainActor static func kapt(roadAddress: String, region: String, api: PublicDataStore) async throws -> [String:String] {
        var matching: [HousingSource] = [], total: Int?, seen = 0
        let requested = BuildingAddress.key(roadAddress)
        for page in 1...1000 {
            try Task.checkCancellation()
            let result = try KaptHousingClient.list(await api.kaptData(.list,parameters:["bjdCode":region,"pageNo":String(page)]),region:region,page:page)
            guard total == nil || total == result.total else { throw BuildingEvaluationError.message("K-apt 보충 목록이 변경되었습니다.") }
            total = result.total; seen += result.records.count
            for source in result.records {
                let basicData = try await api.kaptData(.basic,parameters:["kaptCode":source.aptCode])
                let basic = try KaptHousingClient.info(basicData,code:source.aptCode)
                guard BuildingAddress.split(KaptGateway.text(basic,"doroJuso")).contains(where:{ BuildingAddress.key($0) == requested }) else { continue }
                let facility = try await api.kaptData(.facilities,parameters:["kaptCode":source.aptCode])
                matching.append(try KaptHousingClient.detail(basic:basicData,facilities:facility,source:source))
            }
            if seen == total { break }
        }
        guard seen == total else { throw BuildingEvaluationError.message("K-apt 보충 목록 확인이 완료되지 않았습니다.") }
        return BuildingFacts.consensus(matching.map(\.fields))
    }
}
