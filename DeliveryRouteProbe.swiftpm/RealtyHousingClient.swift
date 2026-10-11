import Foundation

// The mobile page's own JSON/form endpoints. No browser or WebView is opened.
struct RealtyHousingClient {
    private let session: URLSession
    init() {
        let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 45
        session = URLSession(configuration: c)
    }
    func post(_ path: String, _ values: [String: String]) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://www.realtyprice.kr/notice/" + path)!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.realtyprice.kr/notice/m/town/search.do", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        var form = URLComponents(); form.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request); try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "www.realtyprice.kr", data.count <= 50_000_000 else { throw PlannerFailure.message("공시가격 모바일 자료를 읽지 못했습니다. 잠시 뒤 다시 시도하세요.") }
        return data
    }
    static func rows(_ data: Data) throws -> [[String: Any]] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? [String: Any], let list = model["list"] as? [[String: Any]] else { throw PlannerFailure.message("공시가격 목록 응답 형식이 달라졌습니다.") }; return list
    }
    static func text(_ row: [String: Any], _ key: String) -> String { (row[key] as? String ?? (row[key] as? NSNumber)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func areas(sido: String = "", sigungu: String = "") async throws -> [HousingArea] {
        let path = sido.isEmpty ? "getSidoTw" : sigungu.isEmpty ? "getSigunguTw" : "getDongriTw"
        let rows = try Self.rows(await post("m/bjd/" + path + ".do", ["notice_date": "", "reg1": sido, "reg2": sigungu]))
        return rows.map { HousingArea(code: Self.text($0, "CODE"), name: Self.text($0, "NAME")) }
    }
    func list(sido: HousingArea, sigungu: HousingArea, dong: HousingArea) async throws -> HousingRegion {
        let reg = sido.code + sigungu.code, code = reg + dong.code
        var form = Dictionary(uniqueKeysWithValues: ["notice_date", "notice_date_nm", "sido_nm", "sigungu_nm", "road_initial", "road_initial_nm", "road_code", "road_code_nm", "dongri_nm", "search_name", "search_bun"].map { ($0, "") })
        form.merge(["search_gbn": "2", "search_detail_gbn": "2", "sido": sido.code, "sigungu": sigungu.code, "dongri": dong.code, "reg": reg, "road_reg": reg, "eub": dong.code]) { _, x in x }
        let rows = try Self.rows(await post("m/town/getApt.do", form))
        let records = rows.map { row -> HousingSource in
            let apt = Self.text(row, "APT_CODE"), road = Self.text(row, "FULL_ROAD_NAME")
            return HousingSource(id: "realty:" + reg + ":" + apt, aptCode: apt, noticeDate: Self.text(row, "NOTICE_DATE"), regionCode: code,
                fields: ["name": Self.text(row, "MOD_APT_NAME"), "jibunAddress": Self.text(row, "FULL_BJD_NAME"), "roadAddress": Self.road(road) ? road : "", "parcelID": Self.text(row, "SPNU")],
                issues: Self.road(road) ? [] : ["도로명주소 미제공 · 변환 필요"])
        }
        let region = HousingRegion(code: code, sido: sido, sigungu: sigungu, dong: dong, generation: Date().timeIntervalSince1970 * 1000,
            sourceCount: rows.count, records: records, listFetchedMillis: Date().timeIntervalSince1970 * 1000); try region.validate(); return region
    }
    static func matches(_ html: String, _ pattern: String, group: Int = 1) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        return expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { m in
            guard group < m.numberOfRanges, let range = Range(m.range(at: group), in: html) else { return nil }; return String(html[range])
        }
    }
    static func clean(_ html: String) -> String {
        var value = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] { value = value.replacingOccurrences(of: a, with: b) }
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func road(_ text: String) -> Bool { text.range(of: #"(?:대로|로|길)\s+[0-9]+(?:-[0-9]+)?"#, options: .regularExpression) != nil }
    static func parseDetail(_ html: String, source: HousingSource) throws -> HousingSource {
        var next = source
        func field(_ css: String) -> String { clean(matches(html, "<p[^>]*class=[\"']" + css + "[\"'][^>]*>(.*?)</p>").first ?? "") }
        guard !field("addr02").isEmpty || !field("purpose01").isEmpty else { throw PlannerFailure.message("단지 상세 화면 형식이 달라졌습니다.") }
        let roadAddress = field("addr01"); next.fields["roadAddress"] = road(roadAddress) ? roadAddress : ""
        if !field("addr02").isEmpty { next.fields["jibunAddress"] = field("addr02") }
        next.fields["approvalDate"] = field("date01"); next.fields["use"] = field("purpose01")
        next.fields["buildings"] = matches(field("dangi01"), #"([0-9,]+)"#).first?.replacingOccurrences(of: ",", with: "") ?? ""
        next.fields["households"] = matches(html, #"<p[^>]*>\s*([0-9,]+)세대\s*</p>"#).first?.replacingOccurrences(of: ",", with: "") ?? ""
        let x = matches(html, #"x_coord\s*:\s*['\"]([0-9.]+)['\"]"#).first, y = matches(html, #"y_coord\s*:\s*['\"]([0-9.]+)['\"]"#).first
        if let x, let y, let dx = Double(x), let dy = Double(y) {
            next.fields["sourceX"] = x; next.fields["sourceY"] = y
            next.coordinate = RealtyCoordinateProjection.convert(x: dx, y: dy)
        }
        return next
    }
    static func parseBasis(_ html: String, source: HousingSource) throws -> HousingSource {
        var next = source
        func cell(_ label: String) -> String { clean(matches(html, "<th[^>]*>\\s*" + label + "\\s*</th>\\s*<td[^>]*>(.*?)</td>").first ?? "") }
        guard !cell("공시면적 종류").isEmpty || !cell("최고/최저층수").isEmpty else { throw PlannerFailure.message("산정기초자료 형식이 달라졌거나 자료가 없습니다.") }
        next.fields["school"] = cell("교육시설").components(separatedBy: CharacterSet(charactersIn: ",，;")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { $0.hasSuffix("초") || $0.contains("초등학교") || $0.hasSuffix("초교") } ?? ""
        next.fields["parking"] = matches(cell("전체\\s*주차대수"), #"([0-9,]+)"#).first?.replacingOccurrences(of: ",", with: "") ?? ""
        let floors = cell("최고/최저층수").components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if floors.count == 2 { next.fields["highestFloor"] = floors[0]; next.fields["lowestFloor"] = floors[1] }
        let areas = matches(cell("공시면적 종류"), #"([0-9]+(?:\.[0-9]+)?)"#).compactMap(Double.init).map { Int($0.rounded(.down)) }
        next.fields["areas"] = Set(areas).sorted().map(String.init).joined(separator: ", ")
        return next
    }
    func detail(_ source: HousingSource) async throws -> HousingSource {
        let params = ["notice_date": source.noticeDate, "apt_code": source.aptCode, "tiles": "false"]
        let html = String(decoding: try await post("m/town/detail.do", params), as: UTF8.self)
        var next = try Self.parseDetail(html, source: source)
        let select = Self.matches(html, #"<select[^>]*id=['\"]sel_dong['\"][^>]*>(.*?)</select>"#).first ?? ""
        let dongs = Self.matches(select, #"<option[^>]*value=['\"]([^'\"]+)['\"]"#)
        var found = false
        for dong in dongs {
            var form = ["notice_date": source.noticeDate, "apt_code": source.aptCode, "dong_code": dong]
            let hos = try Self.rows(await post("m/town/getHo.do", form))
            guard let ho = hos.first else { continue }; form["ho_code"] = Self.text(ho, "CODE")
            let prices = try Self.rows(await post("m/town/getPriceYear.do", form))
            guard let price = prices.max(by: { Self.text($0, "NOTICE_DATE_ORG") < Self.text($1, "NOTICE_DATE_ORG") }) else { continue }
            form["notice_date"] = Self.text(price, "NOTICE_DATE_ORG"); form["past_yn"] = "1"
            let basis = String(decoding: try await post("m/town/basePriceInfo.do", form), as: UTF8.self)
            do { next = try Self.parseBasis(basis, source: next); next.fields["basisDate"] = Self.text(price, "NOTICE_DATE_NAME"); found = true; break } catch { continue }
        }
        next.issues = []
        if !found { next.issues.append("산정기초자료 미제공") }
        if next.fields["roadAddress", default: ""].isEmpty { next.issues.append("도로명주소 미제공 · 변환 필요") }
        if next.coordinate == nil { next.issues.append("원본 지도 좌표 미제공") }
        next.detailAt = Date(); return next
    }
}
// Matches the Bessel TM + seven-parameter transform used by the source mobile map.
enum RealtyCoordinateProjection {
    static func convert(x: Double, y: Double) -> TMapCoordinate? {
        guard x.isFinite, y.isFinite else { return nil }
        let a = 6_377_397.155, b = 6_356_078.962818, e2 = 1 - (b*b)/(a*a), ep2 = e2/(1-e2)
        func meridian(_ p: Double) -> Double {
            a * ((1-e2/4-3*e2*e2/64-5*pow(e2,3)/256)*p - (3*e2/8+3*e2*e2/32+45*pow(e2,3)/1024)*sin(2*p) + (15*e2*e2/256+45*pow(e2,3)/1024)*sin(4*p) - 35*pow(e2,3)/3072*sin(6*p))
        }
        let m = meridian(38 * .pi/180) + y - 500_000
        let mu = m/(a*(1-e2/4-3*e2*e2/64-5*pow(e2,3)/256)), e1 = (1-sqrt(1-e2))/(1+sqrt(1-e2))
        let p = mu+(3*e1/2-27*pow(e1,3)/32)*sin(2*mu)+(21*e1*e1/16-55*pow(e1,4)/32)*sin(4*mu)+151*pow(e1,3)/96*sin(6*mu)+1097*pow(e1,4)/512*sin(8*mu)
        let n = a/sqrt(1-e2*pow(sin(p),2)), r = a*(1-e2)/pow(1-e2*pow(sin(p),2),1.5), t = pow(tan(p),2), c = ep2*pow(cos(p),2), d = (x-200_000)/n
        let lat = p-(n*tan(p)/r)*(d*d/2-(5+3*t+10*c-4*c*c-9*ep2)*pow(d,4)/24+(61+90*t+298*c+45*t*t-252*ep2-3*c*c)*pow(d,6)/720)
        let lon = 127.0028902777778 * .pi/180 + (d-(1+2*t+c)*pow(d,3)/6+(5-2*c+28*t-3*c*c+8*ep2+24*t*t)*pow(d,5)/120)/cos(p)
        let v = a/sqrt(1-e2*pow(sin(lat),2)), xx = v*cos(lat)*cos(lon), yy = v*cos(lat)*sin(lon), zz = v*(1-e2)*sin(lat)
        let seconds = Double.pi/(180*3600), rx = 1.16*seconds, ry = -2.31*seconds, rz = -1.63*seconds, scale = 1+6.43e-6
        let wx = scale*(xx-rz*yy+ry*zz)-115.80, wy = scale*(rz*xx+yy-rx*zz)+474.99, wz = scale*(-ry*xx+rx*yy+zz)+674.11
        let we2 = 0.0066943799901413165, horizontal = hypot(wx,wy)
        var wlat = atan2(wz,horizontal*(1-we2))
        for _ in 0..<10 { let nv = 6_378_137/sqrt(1-we2*pow(sin(wlat),2)); wlat = atan2(wz+we2*nv*sin(wlat),horizontal) }
        let value = TMapCoordinate(longitude: atan2(wy,wx)*180 / .pi, latitude: wlat*180 / .pi)
        return KakaoRouteAPI.valid(value) ? value : nil
    }
}
