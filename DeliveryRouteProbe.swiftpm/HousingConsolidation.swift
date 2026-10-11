import Foundation

enum HousingIdentity {
    static func roadKey(_ source: HousingSource) -> String {
        if let key = source.addresses?.first?.roadKey, !key.isEmpty { return key }
        let road = source.fields["roadAddress"] ?? ""
        guard RealtyHousingClient.road(road) else { return "" }
        return DeviceShareCodec.addressIdentity(road)
    }
    static func parcel(_ source: HousingSource) -> String {
        let text = source.fields["jibunAddress"] ?? ""
        guard let expression = try? NSRegularExpression(pattern: #"^(.+?(?:동|읍|면|리))\s+(산\s*)?([0-9]+(?:-[0-9]+)?)"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) else { return "" }
        return DeviceShareCodec.addressIdentity(String(text[range]))
    }
    static func dongLabels(_ source: HousingSource) -> [String] {
        (source.fields["dongNames"] ?? "").components(separatedBy: CharacterSet(charactersIn: ",;\n，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func numbers(_ source: HousingSource) -> Set<Int>? {
        guard source.dongScopeConfirmed == true else { return nil }
        let labels = dongLabels(source)
        guard !labels.isEmpty else { return nil }
        var result = Set<Int>()
        for label in labels {
            guard label.range(of: #"^[0-9]{1,6}\s*동?$"#, options: .regularExpression) != nil,
                  let n = Int(label.replacingOccurrences(of: "동", with: "").trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
            result.insert(n)
        }
        return result
    }
    static func connected(_ a: HousingSource, _ b: HousingSource) -> Bool {
        guard let x = numbers(a), let y = numbers(b) else { return false }
        let values = x.union(y).sorted()
        guard let first = values.first, let last = values.last, values.count == last - first + 1 else { return false }
        // Last two digits are the sequence; 101 and 201 belong to different
        // prefixes. This also keeps 1001 and 1101 in separate sequences.
        return Set(values.map { $0 / 100 }).count == 1
    }
    static func office(_ source: HousingSource) -> String {
        let phone = (source.fields["managementOffice"] ?? "").filter(\.isNumber)
        return phone.count >= 8 ? phone : ""
    }
    static func sameRoad(_ a: HousingSource, _ b: HousingSource) -> Bool {
        let x = roadKey(a), y = roadKey(b)
        if !x.isEmpty, !y.isEmpty, x == y { return true }
        // Structured address keys and text keys are never equated; compare
        // normalized source text when only one side has an API response.
        let ar = a.fields["roadAddress"] ?? "", br = b.fields["roadAddress"] ?? ""
        return RealtyHousingClient.road(ar) && RealtyHousingClient.road(br) && DeviceShareCodec.addressIdentity(ar) == DeviceShareCodec.addressIdentity(br)
    }
    static func sameApproval(_ a: HousingSource, _ b: HousingSource) -> Bool {
        let x = (a.fields["approvalDate"] ?? "").filter(\.isNumber), y = (b.fields["approvalDate"] ?? "").filter(\.isNumber)
        return x.isEmpty || y.isEmpty || x == y
    }
    static func candidates(_ realty: HousingSource, kapt: [HousingSource]) -> [HousingSource] {
        kapt.filter { sameRoad(realty, $0) && sameApproval(realty, $0) }
    }
    static func certainMatch(_ realty: HousingSource, _ kapt: HousingSource, realtyPeers: [HousingSource], kaptPeers: [HousingSource]) -> Bool {
        guard sameRoad(realty, kapt), sameApproval(realty, kapt), !parcel(realty).isEmpty, parcel(realty) == parcel(kapt), kapt.fields["registrationStatus"] != "중지" else { return false }
        if let r = numbers(realty), let k = numbers(kapt), !r.isEmpty, r.isSubset(of: k) { return true }
        // An address-wide dong list cannot identify separate management areas.
        // Only a unique one-to-one record with matching date AND scale may be
        // corrected without a source-specific dong list.
        let rdate = realty.fields["approvalDate"] ?? "", kdate = kapt.fields["approvalDate"] ?? ""
        guard !rdate.isEmpty, !kdate.isEmpty,
              let rb = HousingAggregation.integer(realty.fields["buildings"]), let kb = HousingAggregation.integer(kapt.fields["buildings"]), rb == kb, rb > 0,
              let rh = HousingAggregation.integer(realty.fields["households"]), let kh = HousingAggregation.integer(kapt.fields["households"]), rh == kh, rh > 0 else { return false }
        return realtyPeers.filter { sameRoad(realty, $0) }.count == 1 && kaptPeers.filter { sameRoad(realty, $0) }.count == 1
    }
}

enum HousingAggregation {
    static func integer(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty, let n = Int(raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)), (0...10_000_000).contains(n) else { return nil }; return n
    }
    static func yesNo(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "Y", "YES", "있음", "설치", "유": return true
        case "N", "NO", "없음", "미설치", "무": return false
        default: return nil
        }
    }
    static func presence(_ values: [String?]) -> String {
        let flags = values.map(yesNo)
        if flags.contains(true) { return "있음" }
        return !flags.isEmpty && flags.allSatisfy { $0 == false } ? "없음" : "미확인"
    }
    static func derive(_ fields: inout [String: String]) {
        let positiveElevatorEvidence = yesNo(fields["elevatorPresent"]) == true
        fields["elevatorPresent"] = integer(fields["elevators"]).map { $0 > 0 ? "있음" : "없음" } ?? (positiveElevatorEvidence ? "있음" : "미확인")
        fields["chargerPresent"] = presence([fields["chargerGround"], fields["chargerUnderground"]])
        if let parking = integer(fields["parking"]), let households = integer(fields["households"]), households > 0 {
            fields["parkingPerHousehold"] = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(parking) / Double(households))
        } else { fields["parkingPerHousehold"] = "" }
    }
    static func union(_ strings: [String]) -> String {
        var seen = Set<String>()
        return strings.flatMap { $0.components(separatedBy: "\n") }.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
    }
    static func summed(_ key: String, _ records: [HousingSource], requiredScope: Set<Int>? = nil) -> String {
        guard !records.isEmpty else { return "" }
        if records.count == 1, requiredScope == nil { return records[0].fields[key] ?? "" }
        guard records.allSatisfy({ HousingIdentity.numbers($0) != nil }) else { return "" }
        let scope = requiredScope ?? records.reduce(into: Set<Int>()) { $0.formUnion(HousingIdentity.numbers($1) ?? []) }
        let covering = records.filter { HousingIdentity.numbers($0) == scope }
        if !covering.isEmpty {
            let values = Set(covering.compactMap { integer($0.fields[key]) })
            return values.count == 1 && covering.allSatisfy({ integer($0.fields[key]) != nil }) ? String(values.first!) : ""
        }
        var seen = Set<Int>(), sum = 0
        for row in records.sorted(by: { $0.id < $1.id }) {
            guard let numbers = HousingIdentity.numbers(row), numbers.isSubset(of: scope), let value = integer(row.fields[key]) else { return "" }
            if numbers.isSubset(of: seen) { continue }
            guard numbers.isDisjoint(with: seen) else { return "" }
            seen.formUnion(numbers); sum += value
        }
        return seen == scope ? String(sum) : ""
    }
    static func fields(_ records: [HousingSource], preferredKaptID: String? = nil) -> [String: String] {
        let records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.id < $1.id }
        let realty = records.filter { !$0.isKapt }, kapt = records.filter(\.isKapt)
        var result: [String: String] = [:]
        for key in Set(records.flatMap { $0.fields.keys }) { result[key] = union(records.compactMap { $0.fields[key] }) }
        // The primary name remains convenient for search, while each source's
        // name, dates, addresses and categories remain visible in provenance.
        if let main = realty.first { result["name"] = main.fields["name"] ?? "" }
        for key in ["buildings", "households"] { result[key] = summed(key, realty.isEmpty ? kapt : realty) }
        let allKnown = !realty.isEmpty && realty.allSatisfy { HousingIdentity.numbers($0) != nil }
        let scope: Set<Int>? = allKnown ? realty.reduce(into: Set<Int>()) { $0.formUnion(HousingIdentity.numbers($1) ?? []) } : nil
        let preferred = preferredKaptID.flatMap { id in kapt.first { $0.id == id } }
        if let preferred, integer(result["households"]) == nil, integer(preferred.fields["households"]) != nil { result["households"] = preferred.fields["households"] }
        if let preferred, integer(result["buildings"]) == nil, integer(preferred.fields["buildings"]) != nil { result["buildings"] = preferred.fields["buildings"] }
        for key in ["parking", "elevators"] {
            if let preferred, integer(preferred.fields[key]) != nil { result[key] = preferred.fields[key] }
            else if let scope, !kapt.isEmpty {
                let value = summed(key, kapt.filter { HousingIdentity.numbers($0)?.isSubset(of: scope) == true }, requiredScope: scope)
                result[key] = value.isEmpty && key == "parking" ? summed(key, realty) : value
            } else if realty.count == 1, kapt.count == 1, realty[0].fields["households"] == kapt[0].fields["households"], realty[0].fields["buildings"] == kapt[0].fields["buildings"] {
                result[key] = kapt[0].fields[key] ?? realty[0].fields[key] ?? ""
            } else { result[key] = key == "parking" ? summed(key, realty.isEmpty ? kapt : realty) : "" }
        }
        for (key, maximum) in [("highestFloor", true), ("lowestFloor", false)] {
            let values = realty.compactMap { integer($0.fields[key]) }
            if !values.isEmpty { result[key] = String(maximum ? values.max()! : values.min()!) }
        }
        let areas = realty.flatMap { RealtyHousingClient.matches($0.fields["areas"] ?? "", #"([0-9]+(?:\.[0-9]+)?)"#) }.compactMap(Double.init).filter { $0.isFinite && $0 >= 0 && $0 < 100_000 }.map { Int(floor($0)) }
        if !areas.isEmpty { result["areas"] = Set(areas).sorted().map(String.init).joined(separator: ", ") }
        result["dongNames"] = union(records.flatMap(HousingIdentity.dongLabels))
        for key in ["chargerGround", "chargerUnderground"] {
            if !kapt.isEmpty { result[key] = presence(kapt.map { $0.fields[key] }) }
        }
        result["elevatorPresent"] = presence(kapt.map { row in integer(row.fields["elevators"]).map { $0 > 0 ? "있음" : "없음" } })
        derive(&result)
        return result
    }
}

enum HousingConsolidator {
    static func sources(_ region: HousingRegion) -> [HousingSource] { sources(region, overrides: []) }
    static func sources(_ region: HousingRegion, overrides: [HousingEdit]) -> [HousingSource] {
        // An address or connected dong sequence suggests a review candidate,
        // never a merge. Only explicit HousingEdit links define a complex.
        let changes = Dictionary(overrides.map { ($0.id,$0) }, uniquingKeysWith: { _,newer in newer })
        return region.records.map { raw in
            var indexed = raw
            indexed.fields.merge(changes[raw.id]?.fields ?? [:]) { _,user in user }
            indexed.members = [raw]
            return indexed
        }
    }
}
