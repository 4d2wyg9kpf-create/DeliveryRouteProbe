import Foundation
import CoreFoundation

enum PublicDataService: String, Codable, CaseIterable, Identifiable, Hashable {
    case stores, restaurants, cafes, bakery, catering, canteens
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stores: return "상가(상권)정보"
        case .restaurants: return "일반음식점"
        case .cafes: return "휴게음식점"
        case .bakery: return "제과점영업"
        case .catering: return "위탁급식영업"
        case .canteens: return "집단급식소"
        }
    }
    var portalID: String {
        switch self {
        case .stores: return "15012005"
        case .restaurants: return "15154916"
        case .cafes: return "15154921"
        case .bakery: return "15155252"
        case .catering: return "15155159"
        case .canteens: return "15155168"
        }
    }
    var portalURL: URL { URL(string: "https://www.data.go.kr/data/\(portalID)/openapi.do")! }
    var path: String {
        switch self {
        case .stores: return "/B553077/api/open/sdsc2/storeListInRadius"
        case .restaurants: return "/1741000/general_restaurants/info"
        case .cafes: return "/1741000/rest_cafes/info"
        case .bakery: return "/1741000/bakeries/info"
        case .catering: return "/1741000/contract_catering/info"
        case .canteens: return "/1741000/group_meal_facilities/info"
        }
    }
    static var licenses: [PublicDataService] { allCases.filter { $0 != .stores } }
}

enum PublicDataFailure: LocalizedError {
    case message(String), provider(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .provider(let code):
            switch code {
            case "20", "30", "-4": return "인증키 또는 서비스 활용승인을 확인하세요. (\(code))"
            case "31": return "공공데이터 API 이용 기간이 만료되었습니다. 포털에서 갱신하세요."
            case "22", "-10": return "공공데이터 일일 한도를 소진했습니다. 초기화까지 요청을 차단합니다."
            case "23": return "초당 요청 한도에 도달했습니다. 잠시 뒤 직접 다시 조회하세요."
            case "29": return "공공데이터 서버가 요청 IP를 차단했습니다."
            case "10", "-2", "-11": return "공공데이터 요청 조건을 확인하세요. (\(code))"
            default: return "공공데이터 제공 서버 오류입니다. (\(code))"
            }
        }
    }
}

struct PublicBusiness: Codable, Identifiable {
    var id: String
    var name: String
    var address: String
    var category: String
    var categoryCode: String
    var longitude: Double
    var latitude: Double
    var distanceMeters: Double
    var referenceMonth: String
}
struct PublicLicense: Codable, Identifiable {
    var id: String
    var name: String
    var service: PublicDataService
    var address: String
    var phone: String
    var permissionDate: String
    var status: String
    var updatedAt: String
    var authorityCode: String
}
struct PublicDataPage {
    var rows: [[String: Any]]
    var total: Int
    var page: Int
    var pageSize: Int
    var referenceMonth: String
}

enum PublicDataParser {
    static let daejeonAuthorities = ["6300000", "3640000", "3650000", "3660000", "3670000", "3680000"]
    static func string(_ item: [String: Any], _ key: String) -> String {
        if let value = item[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = item[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
        return ""
    }
    static func integer(_ item: [String: Any], _ key: String) -> Int? {
        let text = string(item, key)
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text), (0...10_000_000).contains(value) else { return nil }
        return value
    }
    static func page(_ data: Data, expectedPage: Int, expectedSize: Int) throws -> PublicDataPage {
        guard data.count <= 8_000_000 else { throw PublicDataFailure.message("공공데이터 응답이 너무 큽니다.") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
            // Gateway errors can be XML even when JSON was requested. Never
            // surface raw XML/URLs because they may contain an echoed key.
            for tag in ["returnReasonCode", "resultCode"] {
                if let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) {
                    let code = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if code.range(of: #"^-?\d{1,4}$"#, options: .regularExpression) != nil { throw PublicDataFailure.provider(code) }
                }
            }
            throw PublicDataFailure.message("공공데이터 JSON 응답을 확인하지 못했습니다.")
        }
        let response = root["response"] as? [String: Any] ?? root
        let header = response["header"] as? [String: Any] ?? response
        let code = string(header, "resultCode")
        guard ["0", "00", "0000"].contains(code) else {
            guard code.range(of: #"^-?\d{1,4}$"#, options: .regularExpression) != nil else { throw PublicDataFailure.message("공공데이터 응답 결과코드를 확인하지 못했습니다.") }
            throw PublicDataFailure.provider(code)
        }
        let body = response["body"] as? [String: Any] ?? response
        guard let total = integer(body, "totalCount"), let page = integer(body, "pageNo"), let size = integer(body, "numOfRows"),
              page == expectedPage, size == expectedSize else { throw PublicDataFailure.message("공공데이터 응답의 페이지·건수를 확인하지 못했습니다.") }
        let items = body["items"]
        let raw: Any? = (items as? [String: Any])?["item"] ?? items
        let rows: [[String: Any]]
        if let array = raw as? [[String: Any]] { rows = array }
        else if let item = raw as? [String: Any], !item.isEmpty { rows = [item] }
        else if total == 0, raw == nil || raw is NSNull || (raw as? String) == "" || (raw as? [String: Any])?.isEmpty == true { rows = [] }
        else { throw PublicDataFailure.message("공공데이터 업체 목록 형식이 다릅니다.") }
        let expectedRows = min(size, max(0, total - (page - 1) * size))
        guard rows.count == expectedRows, total == 0 ? rows.isEmpty : !rows.isEmpty else { throw PublicDataFailure.message("공공데이터 페이지가 비어 있거나 건수가 다릅니다.") }
        return PublicDataPage(rows: rows, total: total, page: page, pageSize: size, referenceMonth: string(body, "stdrYm"))
    }
    static func distance(longitude: Double, latitude: Double, center: TMapCoordinate) -> Double {
        let rad = Double.pi / 180
        let a = pow(sin((latitude - center.latitude) * rad / 2), 2) + cos(latitude * rad) * cos(center.latitude * rad) * pow(sin((longitude - center.longitude) * rad / 2), 2)
        return 6_371_008.8 * 2 * atan2(sqrt(min(1, a)), sqrt(max(0, 1 - a)))
    }
    static func business(_ item: [String: Any], center: TMapCoordinate, radius: Int, month: String) -> PublicBusiness? {
        let id = string(item, "bizesId"), name = string(item, "bizesNm"), branch = string(item, "brchNm")
        guard !id.isEmpty, !name.isEmpty, let longitude = Double(string(item, "lon")), let latitude = Double(string(item, "lat")),
              longitude.isFinite, latitude.isFinite, (124...132).contains(longitude), (32...40).contains(latitude) else { return nil }
        let meters = distance(longitude: longitude, latitude: latitude, center: center)
        guard meters <= Double(radius) + 0.5 else { return nil }
        let road = string(item, "rdnmAdr"), lot = string(item, "lnoAdr")
        return PublicBusiness(id: id, name: name + (branch.isEmpty ? "" : " " + branch), address: road.isEmpty ? lot : road,
            category: string(item, "indsSclsNm"), categoryCode: string(item, "indsLclsCd"), longitude: longitude, latitude: latitude,
            distanceMeters: meters, referenceMonth: string(item, "stdrYm").isEmpty ? month : string(item, "stdrYm"))
    }
    static func date(_ text: String) -> String? {
        let clean = text.replacingOccurrences(of: "-", with: "")
        guard clean.count == 8, clean.allSatisfy(\.isNumber) else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Seoul"); formatter.dateFormat = "yyyyMMdd"; formatter.isLenient = false
        guard let date = formatter.date(from: clean), formatter.string(from: date) == clean else { return nil }
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
    static func license(_ item: [String: Any], service: PublicDataService, from: String, through: String) -> PublicLicense? {
        let authority = string(item, "OPN_ATMY_GRP_CD")
        let status = string(item, "SALS_STTS_NM"), detail = string(item, "DTL_SALS_STTS_NM")
        let statuses = status + detail
        guard daejeonAuthorities.contains(authority), ["01", "1"].contains(string(item, "SALS_STTS_CD")),
              !["폐업", "휴업", "말소", "취소", "정지", "미영업"].contains(where: { statuses.contains($0) }),
              string(item, "CLSBIZ_YMD").isEmpty,
              let date = date(string(item, "LCPMT_YMD")), date >= from, date <= through else { return nil }
        let id = string(item, "MNG_NO"), name = string(item, "BPLC_NM")
        guard !id.isEmpty, !name.isEmpty else { return nil }
        let road = string(item, "ROAD_NM_ADDR"), lot = string(item, "LOTNO_ADDR")
        // Query by authority, so a missing road address does not lose a permit.
        // Reject contradictory non-Daejeon addresses instead of matching any
        // occurrence of the word '대전' inside a road/business name.
        let address = road.isEmpty ? lot : road
        if !address.isEmpty, !address.hasPrefix("대전광역시 "), !address.hasPrefix("대전 ") { return nil }
        return PublicLicense(id: service.rawValue + ":" + authority + ":" + id, name: name, service: service, address: address,
            phone: string(item, "TELNO"), permissionDate: date, status: status.isEmpty ? "영업/정상" : status,
            updatedAt: string(item, "DAT_UPDT_PNT"), authorityCode: authority)
    }
}
