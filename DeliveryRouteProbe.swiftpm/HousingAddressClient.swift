import Foundation

private final class HousingAddressNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct HousingAddressClient {
    private let delegate = HousingAddressNetworkDelegate()
    private let session: URLSession
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    init(transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.transport = transport
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    static func parse(_ data: Data, at: Date = Date()) throws -> (addresses: [HousingAddressEvidence], total: Int) {
        guard data.count <= 8_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any], let common = results["common"] as? [String: Any] else { throw PlannerFailure.message("도로명주소 API 응답 형식이 다릅니다.") }
        guard KaptHousingClient.text(common,"errorCode") == "0" else { throw PlannerFailure.message("도로명주소 API 키·승인·검색어를 확인하세요.") }
        guard let total = HousingAggregation.integer(KaptHousingClient.text(common,"totalCount")) else { throw DeviceShareError.invalid }
        let rows = results["juso"] as? [[String: Any]] ?? []
        let addresses = rows.map { row -> HousingAddressEvidence in
            func value(_ key: String) -> String { KaptHousingClient.text(row,key) }
            let labels = value("detBdNmList").components(separatedBy: CharacterSet(charactersIn:",;\n，")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return HousingAddressEvidence(roadAddress:value("roadAddrPart1").isEmpty ? value("roadAddr") : value("roadAddrPart1"), jibunAddress:value("jibunAddr"),
                roadKey:[value("rnMgtSn"),value("udrtYn"),value("buldMnnm"),value("buldSlno")].joined(separator:"|"), buildingID:value("bdMgtSn"), dongNames:labels,
                communityCenter:value("hemdNm"), relatedParcels:value("relJibun"), fetchedAt:at,
                administrativeCode:value("admCd"), parcelMain:value("lnbrMnnm"), parcelSub:value("lnbrSlno"), mountain:value("mtYn"))
        }
        guard addresses.allSatisfy({ !$0.buildingID.isEmpty && !$0.roadAddress.isEmpty && !$0.roadKey.hasPrefix("|") }) else { throw DeviceShareError.invalid }
        return (addresses,total)
    }
    func lookup(_ source: HousingSource, key: String) async throws -> HousingSource {
        guard !key.isEmpty else { throw PlannerFailure.message("도로명주소 API 승인키를 저장하세요.") }
        let road = source.fields["roadAddress"] ?? ""
        let keyword = RealtyHousingClient.road(road) ? road : source.fields["jibunAddress"] ?? ""
        guard !keyword.isEmpty else { throw PlannerFailure.message("도로명주소 또는 지번주소가 필요합니다.") }
        var addresses: [HousingAddressEvidence] = [], total: Int?
        for page in 1...10 {
            try Task.checkCancellation()
            var url = URLComponents(); url.scheme = "https"; url.host = "business.juso.go.kr"; url.path = "/addrlink/addrLinkApi.do"
            url.queryItems = ["confmKey":key,"currentPage":String(page),"countPerPage":"100","keyword":keyword,"resultType":"json","addInfoYn":"Y"].sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
            let request = URLRequest(url:url.url!,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData)
            let data: Data, response: URLResponse
            do { if let transport { (data,response) = try await transport(request) } else { (data,response) = try await session.data(for:request) } }
            catch is CancellationError { throw CancellationError() }
            catch { throw PlannerFailure.message("도로명주소 API에 연결하지 못했습니다.") }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "business.juso.go.kr" else { throw PlannerFailure.message("도로명주소 API 응답 출처를 확인하지 못했습니다.") }
            let part = try Self.parse(data)
            if let total, total != part.total { throw PlannerFailure.message("주소 검색 결과가 변경되었습니다. 다시 확인하세요.") }
            total = part.total; addresses.append(contentsOf:part.addresses)
            if addresses.count >= part.total { break }
            guard !part.addresses.isEmpty, page < 10 else { throw PlannerFailure.message("주소 결과가 너무 많습니다. 주소를 구체적으로 수정하세요.") }
        }
        let exact = addresses.filter { a in
            var other = source; other.fields["roadAddress"] = a.roadAddress; other.fields["jibunAddress"] = a.jibunAddress
            return RealtyHousingClient.road(road) ? HousingIdentity.sameRoad(source,other) : (!HousingIdentity.parcel(source).isEmpty && HousingIdentity.parcel(source) == HousingIdentity.parcel(other))
        }
        guard !exact.isEmpty else { throw PlannerFailure.message("주소 API에서 동일 주소를 확인하지 못했습니다. 원본 주소를 확인하세요.") }
        var next = source; next.addresses = exact
        next.fields["communityCenter"] = HousingAggregation.union(exact.map(\.communityCenter))
        next.fields["jusoDongNames"] = HousingAggregation.union(exact.flatMap(\.dongNames))
        if !RealtyHousingClient.road(road) {
            next.fields["roadAddress"] = HousingAggregation.union(exact.map(\.roadAddress)); next.issues.removeAll { $0.contains("도로명주소") }
        }
        // Address-wide building names are evidence, not confirmed membership of
        // one K-apt management area or one price-notice complex.
        return next
    }
}
