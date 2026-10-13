import Foundation

enum BuildingLedgerClient {
    static func parameters(_ address: HousingAddressEvidence, page: Int) throws -> [String: String] {
        let admin = address.administrativeCode ?? ""
        guard admin.range(of: #"^\d{10}$"#, options: .regularExpression) != nil,
              let main = Int(address.parcelMain ?? ""), let sub = Int(address.parcelSub ?? ""),
              (0...9999).contains(main), (0...9999).contains(sub), ["0","1"].contains(address.mountain ?? "") else {
            throw BuildingEvaluationError.message("주소 API의 법정동·지번 정보를 확인하지 못했습니다. 건축물대장을 다른 지번으로 조회하지 않았습니다.")
        }
        return ["sigunguCd":String(admin.prefix(5)), "bjdongCd":String(admin.suffix(5)), "platGbCd":address.mountain!,
                "bun":String(format:"%04d",main), "ji":String(format:"%04d",sub), "pageNo":String(page)]
    }
    static func parse(_ data: Data, address: HousingAddressEvidence, page: Int, now: Date = Date()) throws -> (buildings: [EvaluationBuilding], total: Int, rowCount: Int) {
        let expected = try parameters(address, page: page), body = try KaptGateway.body(data)
        func text(_ row: [String: Any], _ key: String) -> String { KaptGateway.text(row, key) }
        guard let total = Int(text(body,"totalCount")), (0...100_000).contains(total), Int(text(body,"pageNo")) == page else { throw DeviceShareError.invalid }
        let raw = (body["items"] as? [String: Any])?["item"] ?? body["items"]
        let rows = raw as? [[String: Any]] ?? (raw as? [String: Any]).map { [$0] } ?? []
        guard rows.count == min(100,max(0,total-(page-1)*100)) else { throw BuildingEvaluationError.message("건축물대장 페이지가 누락되었습니다.") }
        var buildings: [EvaluationBuilding] = []
        for row in rows {
            for key in ["sigunguCd","bjdongCd","platGbCd","bun","ji"] {
                guard Int(text(row,key)) == Int(expected[key] ?? "") else { throw BuildingEvaluationError.message("건축물대장 응답의 지번이 조회한 주소와 다릅니다.") }
            }
            guard text(row,"mainAtchGbCd") == "0" else { continue }
            let road = text(row,"newPlatPlc")
            // Filter other buildings on the same parcel with a different road address.
            guard road.isEmpty || BuildingAddress.key(road) == BuildingAddress.key(address.roadAddress) else { continue }
            var fields: [String: String] = [:]
            let mapping = ["approvalDate":"useAprDay", "households":"hhldCnt", "families":"fmlyCnt", "highestFloor":"grndFlrCnt", "basementFloors":"ugrndFlrCnt", "height":"heit", "buildingArea":"archArea", "totalArea":"totArea", "landArea":"platArea", "structure":"strctCdNm", "buildingCoverage":"bcRat", "floorAreaRatio":"vlRat", "earthquakeDesign":"rserthqkDsgnApplyYn"]
            for (key, raw) in mapping { fields[key] = text(row,raw) }
            fields["use"] = [text(row,"mainPurpsCdNm"),text(row,"etcPurps")].filter { !$0.isEmpty }.joined(separator:" · ")
            let approval = fields["approvalDate",default:""]
            if approval.count == 8 { fields["approvalDate"] = String(approval.prefix(4)) + "-" + String(approval.dropFirst(4).prefix(2)) + "-" + String(approval.suffix(2)) }
            func sum(_ names: [String]) -> String {
                let values = names.compactMap { Int(text(row,$0)) }
                return values.count == names.count ? String(values.reduce(0,+)) : ""
            }
            fields["elevators"] = sum(["rideUseElvtCnt","emgenUseElvtCnt"])
            fields["parking"] = sum(["indrMechUtcnt","oudrMechUtcnt","indrAutoUtcnt","oudrAutoUtcnt"])
            let building = EvaluationBuilding(id:text(row,"mgmBldrgstPk"),roadAddress:address.roadAddress,name:text(row,"bldNm"),dongName:text(row,"dongNm"),fields:fields,fetchedAt:now)
            try building.validate(); buildings.append(building)
        }
        return (buildings,total,rows.count)
    }
    @MainActor static func lookup(_ address: HousingAddressEvidence, api: PublicDataStore) async throws -> [EvaluationBuilding] {
        var buildings: [EvaluationBuilding] = [], seen = 0, total: Int?
        for page in 1...1000 {
            try Task.checkCancellation()
            let data = try await api.kaptData(.buildingTitle,parameters:parameters(address,page:page))
            let part = try parse(data,address:address,page:page)
            guard total == nil || total == part.total else { throw BuildingEvaluationError.message("건축물대장 전체 건수가 변경되었습니다. 다시 조회하세요.") }
            total = part.total; seen += part.rowCount; buildings.append(contentsOf:part.buildings)
            if seen == part.total { break }
        }
        guard seen == total, Set(buildings.map(\.id)).count == buildings.count else { throw BuildingEvaluationError.message("건축물대장 수집이 완료되지 않았습니다.") }
        return buildings
    }
}
