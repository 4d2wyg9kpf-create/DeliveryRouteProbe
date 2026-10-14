import Foundation

// Form fields and endpoints come from /notice/m/town/search.do's getData,
// getRoadInitial, getRoad and getApt functions (checked 2026-10-14).
@MainActor final class RealtyAddressSearchClient {
    let client: RealtyHousingClient
    private var provinces: [HousingArea]?
    private var districts: [String:[HousingArea]] = [:]
    private var initials: [String:[[String:Any]]] = [:]
    private var roadCodes: [String:String] = [:]
    init(client: RealtyHousingClient = RealtyHousingClient()) { self.client = client }
    static func initial(_ value: String) -> String {
        guard let scalar = value.unicodeScalars.first else { return "" }
        if (0xAC00...0xD7A3).contains(scalar.value) {
            let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
            return String(initials[Int((scalar.value-0xAC00)/588)])
        }
        return String(scalar).uppercased()
    }
    private func region(_ road: String) async throws -> (String,String,String,String) {
        guard let key = BuildingAddress.key(road) else { throw BuildingEvaluationError.message("K-apt 도로명주소 형식을 확인하세요.") }
        let words = key.split(separator:" ").map(String.init)
        guard words.count >= 3 else { throw BuildingEvaluationError.message("도로명주소에 시도·시군구가 필요합니다.") }
        if provinces == nil { provinces = try await client.areas() }
        func canonicalProvince(_ name: String) -> String { BuildingAddress.key(name + " 가상로 1")?.components(separatedBy:" ").first ?? name }
        let matches = (provinces ?? []).filter { canonicalProvince($0.name) == words[0] }
        guard matches.count == 1, matches[0].code.count == 2 else { throw BuildingEvaluationError.message("공시가격 검색의 시도를 확인하지 못했습니다.") }
        let sido = matches[0].code
        let districtName = words.dropFirst().dropLast(2).joined(separator:" ")
        if districts[sido] == nil { districts[sido] = try await client.areas(sido:sido) }
        let options = districts[sido] ?? []
        // Sejong may have no separate district token. Only a single exact
        // provider district can be used; never guess between several rows.
        let found = options.filter { BuildingAddress.clean($0.name) == districtName || (districtName.isEmpty && options.count == 1) }
        guard found.count == 1, found[0].code.count == 3 else { throw BuildingEvaluationError.message("공시가격 검색의 시군구를 확인하지 못했습니다: " + districtName) }
        return (sido,found[0].code,words[words.count-2],words[words.count-1])
    }
    static func form(sido: String, sigungu: String, roadCode: String = "", dongCode: String = "", number: String) -> [String:String] {
        var result = Dictionary(uniqueKeysWithValues:["notice_date","notice_date_nm","sido_nm","sigungu_nm","road_initial","road_initial_nm","road_code_nm","dongri_nm","search_name"].map { ($0,"") })
        let reg = sido + sigungu
        result.merge(["search_gbn":"2","search_detail_gbn":roadCode.isEmpty ? "2" : "1","sido":sido,"sigungu":sigungu,
            "road_reg":reg,"reg":reg,"road_code":roadCode,"dongri":dongCode,"eub":dongCode,"search_bun":number]) { _,new in new }
        return result
    }
    static func parse(_ data: Data, reg: String, fallbackRegion: String? = nil) throws -> [HousingSource] {
        let rows = try RealtyHousingClient.rows(data)
        guard rows.count <= 100_000 else { throw DeviceShareError.invalid }
        var result: [String:HousingSource] = [:]
        for row in rows {
            let code = RealtyHousingClient.text(row,"APT_CODE"), parcel = RealtyHousingClient.text(row,"SPNU")
            let region = parcel.count >= 19 && parcel.prefix(10).allSatisfy(\.isNumber) ? String(parcel.prefix(10)) : fallbackRegion ?? ""
            guard !code.isEmpty, code.utf8.count <= 100, region.count == 10, region.hasPrefix(reg), region.allSatisfy(\.isNumber) else {
                throw BuildingEvaluationError.message("주소 검색 결과의 단지 코드·법정동 식별자를 확인하지 못했습니다.")
            }
            let road = RealtyHousingClient.text(row,"FULL_ROAD_NAME")
            let source = HousingSource(id:"realty:" + reg + ":" + code,aptCode:code,noticeDate:RealtyHousingClient.text(row,"NOTICE_DATE"),regionCode:region,
                fields:["name":RealtyHousingClient.text(row,"MOD_APT_NAME"),"jibunAddress":RealtyHousingClient.text(row,"FULL_BJD_NAME"),
                    "roadAddress":RealtyHousingClient.road(road) ? road : "","parcelID":parcel],issues:RealtyHousingClient.road(road) ? [] : ["도로명주소 미제공"])
            if let previous = result[source.id], previous.noticeDate != source.noticeDate { throw BuildingEvaluationError.message("같은 단지의 검색 결과가 중복되어 확인을 보류했습니다.") }
            result[source.id] = source
        }
        return result.values.sorted { $0.id < $1.id }
    }
    func road(_ address: String) async throws -> [HousingSource] {
        let (sido,sigungu,roadName,number) = try await region(address)
        let reg = sido + sigungu, roadKey = reg + "|" + roadName
        if roadCodes[roadKey] == nil {
            if initials[reg] == nil { initials[reg] = try RealtyHousingClient.rows(await client.post("m/road/getRoadInitialTw.do",["reg":reg])) }
            let wanted = Self.initial(roadName)
            let possible = (initials[reg] ?? []).filter { row in
                let name = RealtyHousingClient.text(row,"NAME"), code = RealtyHousingClient.text(row,"CODE")
                return name == wanted || code == wanted || Self.initial(name) == wanted
            }
            guard !possible.isEmpty else { return [] }
            var codes = Set<String>()
            for item in possible {
                let initial = RealtyHousingClient.text(item,"CODE")
                guard !initial.isEmpty else { throw DeviceShareError.invalid }
                let rows = try RealtyHousingClient.rows(await client.post("m/road/getRoadTw.do",["reg":reg,"road_initial":initial]))
                for row in rows where BuildingAddress.clean(RealtyHousingClient.text(row,"NAME")) == roadName {
                    let code = RealtyHousingClient.text(row,"CODE"); guard !code.isEmpty else { throw DeviceShareError.invalid }; codes.insert(code)
                }
            }
            guard codes.count <= 1 else { throw BuildingEvaluationError.message("같은 도로명에 검색 코드가 여러 개 있습니다. 주소를 확인하세요.") }
            guard let code = codes.first else { return [] }; roadCodes[roadKey] = code
        }
        let form = Self.form(sido:sido,sigungu:sigungu,roadCode:roadCodes[roadKey]!,number:number)
        let rows = try Self.parse(await client.post("m/town/getApt.do",form),reg:reg)
        let key = BuildingAddress.key(address)
        return rows.filter { BuildingAddress.split($0.fields["roadAddress",default:""]).contains { BuildingAddress.key($0) == key } }
    }
    static func parcelID(_ address: HousingAddressEvidence) throws -> String {
        guard let code = address.administrativeCode, code.range(of:#"^\d{10}$"#,options:.regularExpression) != nil,
              let main = Int(address.parcelMain ?? ""), (1...9999).contains(main),
              let sub = Int(address.parcelSub ?? ""), (0...9999).contains(sub), ["0","1"].contains(address.mountain ?? "") else {
            throw BuildingEvaluationError.message("주소 API의 법정동·지번 번호가 미확인입니다.")
        }
        return code + (address.mountain == "1" ? "2" : "1") + String(format:"%04d%04d",main,sub)
    }
    func jibun(_ address: HousingAddressEvidence) async throws -> [HousingSource] {
        let parcel = try Self.parcelID(address), code = String(parcel.prefix(10))
        let number = (address.mountain == "1" ? "산 " : "") + String(Int(address.parcelMain!)!) + ((Int(address.parcelSub!)! > 0) ? "-" + String(Int(address.parcelSub!)!) : "")
        let form = Self.form(sido:String(code.prefix(2)),sigungu:String(code.dropFirst(2).prefix(3)),dongCode:String(code.suffix(5)),number:number)
        let rows = try Self.parse(await client.post("m/town/getApt.do",form),reg:String(code.prefix(5)),fallbackRegion:code)
        return rows.filter { source in
            let other = source.fields["parcelID",default:""]
            if other.range(of:#"^\d{19}$"#,options:.regularExpression) != nil { return other == parcel }
            // Missing PNU is not an excuse to attach every complex in the dong.
            var target = source; target.fields["jibunAddress"] = address.jibunAddress
            let a = HousingIdentity.parcel(source), b = HousingIdentity.parcel(target)
            return !a.isEmpty && a == b && source.regionCode == code
        }
    }
    func search(_ road: String, addresses: (String) async throws -> [HousingAddressEvidence]) async throws -> (KaptPriceSearch,[HousingSource]) {
        var sources = try await self.road(road), evidence: [HousingAddressEvidence] = [], method = "road"
        if sources.isEmpty {
            evidence = try await addresses(road)
            guard !evidence.isEmpty, evidence.allSatisfy({ BuildingAddress.key($0.roadAddress) == BuildingAddress.key(road) }) else { throw BuildingEvaluationError.message("같은 도로명주소의 지번 변환을 확인하지 못했습니다.") }
            var parcels = Set<String>(); method = "road+jibun"
            for address in evidence {
                let parcel = try Self.parcelID(address)
                if parcels.insert(parcel).inserted { sources.append(contentsOf:try await jibun(address)) }
            }
        }
        sources = Dictionary(sources.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a }).values.sorted { $0.id < $1.id }
        let search = KaptPriceSearch(roadAddress:road,method:method,sourceIDs:sources.map(\.id),addresses:evidence,fetchedAt:Date())
        try search.validate(); return (search,sources)
    }
}
