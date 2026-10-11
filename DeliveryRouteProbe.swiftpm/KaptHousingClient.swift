import Foundation
import CoreFoundation

// Verified against the provider's current V5/V4 schemas. A URLSession request
// replaces the public pages; no WebView, login or browser session is involved.
enum KaptHousingClient {
    static func text(_ row: [String: Any], _ key: String) -> String {
        if let value = row[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = row[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
        return ""
    }
    static func body(_ data: Data) throws -> [String: Any] { try KaptGateway.body(data) }
    static func list(_ data: Data, region: String, page: Int) throws -> (records: [HousingSource], total: Int) {
        let body = try body(data)
        guard let total = HousingAggregation.integer(text(body, "totalCount")), let current = Int(text(body, "pageNo")), current == page else { throw PlannerFailure.message("K-apt 목록 페이지·전체 건수가 다릅니다.") }
        let raw = (body["items"] as? [String: Any])?["item"] ?? body["items"]
        let rows = raw as? [[String: Any]] ?? (raw as? [String: Any]).map { [$0] } ?? []
        let expected = min(100, max(0,total - (page - 1) * 100))
        guard rows.count == expected else { throw PlannerFailure.message("K-apt 목록이 누락되었습니다. 수집 완료로 처리하지 않았습니다.") }
        let records = try rows.map { row -> HousingSource in
            let code = text(row, "kaptCode")
            guard !code.isEmpty, text(row, "bjdCode") == region else { throw PlannerFailure.message("K-apt 단지 코드·법정동이 일치하지 않습니다.") }
            return HousingSource(id: "kapt:" + region + ":" + code, aptCode: code, noticeDate: "", regionCode: region, fields: ["name": text(row,"kaptName")])
        }
        guard Set(records.map(\.id)).count == records.count else { throw DeviceShareError.invalid }; return (records,total)
    }
    static func info(_ data: Data, code: String) throws -> [String: Any] {
        let body = try body(data)
        guard let item = body["item"] as? [String: Any], text(item,"kaptCode") == code else { throw PlannerFailure.message("K-apt 상세의 단지 코드가 다릅니다.") }; return item
    }
    static func detail(basic: Data, facilities: Data, source: HousingSource) throws -> HousingSource {
        let base = try info(basic,code: source.aptCode), facility = try info(facilities,code: source.aptCode)
        var next = source
        let baseKeys = ["name":"kaptName", "roadAddress":"doroJuso", "jibunAddress":"kaptAddr", "saleType":"codeSaleNm", "heating":"codeHeatNm", "corridor":"codeHallNm", "buildings":"kaptDongCnt", "households":"kaptdaCnt", "approvalDate":"kaptUsedate", "managementOffice":"kaptTel"]
        for (key, field) in baseKeys { next.fields[key] = text(base,field) }
        let date = next.fields["approvalDate",default:""].filter(\.isNumber)
        if date.count == 8 { next.fields["approvalDate"] = String(date.prefix(4)) + "-" + String(date.dropFirst(4).prefix(2)) + "-" + String(date.suffix(2)) }
        next.fields["waterSupply"] = text(facility,"codeWsupply")
        next.fields["elevators"] = text(facility,"kaptdEcnt")
        next.fields["parkingGround"] = text(facility,"kaptdPcnt"); next.fields["parkingUnderground"] = text(facility,"kaptdPcntu")
        if let a = HousingAggregation.integer(next.fields["parkingGround"]), let b = HousingAggregation.integer(next.fields["parkingUnderground"]) { next.fields["parking"] = String(a + b) } else { next.fields["parking"] = "" }
        for (field,key) in [("chargerGround","groundElChargerCnt"),("chargerUnderground","undergroundElChargerCnt")] {
            let count = HousingAggregation.integer(text(facility,key))
            next.fields[field] = count.map { $0 > 0 ? "있음" : "없음" } ?? "미확인"
            next.fields[field + "Count"] = count.map(String.init) ?? ""
        }
        next.fields["registrationStatus"] = text(facility,"useYn") == "N" ? "중지" : text(facility,"useYn") == "Y" ? "사용" : "미확인"
        next.rawData = try JSONSerialization.data(withJSONObject: ["basic":base,"facilities":facility],options:[.sortedKeys])
        next.detailAt = Date(); next.issues = []
        if next.fields["registrationStatus"] == "중지" { next.issues.append("K-apt 사용 중지 등록 · 현존·멸실 여부 별도 확인") }
        HousingAggregation.derive(&next.fields); return next
    }
}

