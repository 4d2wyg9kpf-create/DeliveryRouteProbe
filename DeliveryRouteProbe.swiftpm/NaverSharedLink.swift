import Foundation

enum NaverSharedLink {
    enum Kind: Equatable { case place(String), folder(String), mapSelection, short }
    struct Target: Equatable { let kind: Kind; let url: URL }
    enum Failure: LocalizedError {
        case missing, multiple
        var errorDescription: String? {
            switch self {
            case .missing: return "네이버 지도에서 공유한 장소·주소 또는 저장 목록 링크를 붙여넣어 주세요."
            case .multiple: return "한 번에 장소 하나 또는 저장 목록 하나의 링크를 붙여넣어 주세요."
            }
        }
    }
    static func parse(_ text: String) throws -> Target {
        guard text.utf8.count <= 8_000 else { throw Failure.missing }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let values = matches.compactMap { $0.url }
        let accepted = values.compactMap(target)
        guard !accepted.isEmpty else { throw Failure.missing }
        guard accepted.count == 1 else { throw Failure.multiple }
        return accepted[0]
    }
    // Do not take coordinates from a URL or treat a broad search as a place.
    // This helper checks a rendered address label only; it does not
    // geocode a share title or choose the selected point.
    static func roadAddress(_ value: String) -> String? {
        guard value.utf8.count <= 2_000 else { return nil }
        let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let regions = ["서울", "서울특별시", "부산", "부산광역시", "대구", "대구광역시", "인천", "인천광역시", "광주", "광주광역시", "대전", "대전광역시", "울산", "울산광역시", "세종", "세종특별자치시", "경기", "경기도", "강원", "강원도", "강원특별자치도", "충북", "충청북도", "충남", "충청남도", "전북", "전라북도", "전북특별자치도", "전남", "전라남도", "경북", "경상북도", "경남", "경상남도", "제주", "제주도", "제주특별자치도"]
        let region = regions.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let count = normalized.hasPrefix("세종 ") || normalized.hasPrefix("세종특별자치시 ") ? "0,3" : "1,3"
        let pattern = "^((?:" + region + ")\\s+(?:[가-힣0-9·.]+(?:시|군|구|읍|면)\\s+){" + count + "}[가-힣0-9·.]+(?:대로|로|길)\\s*(?:지하\\s*)?[0-9]{1,6}(?:-[0-9]{1,6})?)(?:\\s*[,（(].*)?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let range = Range(match.range(at: 1), in: normalized) else { return nil }
        return String(normalized[range])
    }
    static func target(_ url: URL) -> Target? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        func match(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let result = expression.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
                  let range = Range(result.range(at: 1), in: url.path) else { return nil }
            return String(url.path[range])
        }
        func place(_ id: String) -> Target {
            Target(kind: .place(id), url: URL(string: "https://map.naver.com/p/entry/place/" + id)!)
        }
        func folder(_ id: String) -> Target {
            Target(kind: .folder(id), url: URL(string: "https://map.naver.com/p/favorite/myPlace/folder/" + id)!)
        }
        if host == "naver.me", match("^/([A-Za-z0-9]{1,64})/?$") != nil,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            guard let secure = components.url else { return nil }
            return Target(kind: .short, url: secure)
        }
        if host == "map.naver.com" {
            if let id = match("^/(?:p|v5)/favorite/myPlace/folder/([A-Za-z0-9_-]{1,128})(?:/|$)") { return folder(id) }
            if let id = match("^/(?:p|v5)/(?:entry|search/[^/]+)/place/([0-9]{1,20})(?:/|$)"),
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                if let secure = components.url { return Target(kind: .place(id), url: secure) }
            }
            if match("^/(?:p|v5)/search/([^/]+)/?$") != nil,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                if let secure = components.url { return Target(kind: .mapSelection, url: secure) }
            }
            if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), ["/", "/p", "/p/", "/v5", "/v5/", "/index.nhn", "/local/siteview.nhn"].contains(url.path) {
                let items = parts.queryItems ?? []
                let ids = items.filter { $0.name == "pinId" || $0.name == "code" }.compactMap(\.value)
                // Coordinates alone do not identify a POI. Keep a selected-pin
                // URL intact and verify its rendered marker in the map reader.
                if items.contains(where: { $0.name == "lat" }) && items.contains(where: { $0.name == "lng" }) {
                    var components = parts; components.scheme = "https"
                    if let secure = components.url { return Target(kind: .mapSelection, url: secure) }
                }
                if ids.count == 1, ids[0].range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil { return place(ids[0]) }
            }
        }
        if ["m.place.naver.com", "pcmap.place.naver.com", "place.map.naver.com"].contains(host),
           let id = match("^/(?:place|restaurant|cafe|hospital|beauty|hairshop|accommodation)/([0-9]{1,20})(?:/|$)") { return place(id) }
        if host == "pages.map.naver.com", let id = match("^/save-pages/pc/detail-list/([A-Za-z0-9_-]{1,128})(?:/|$)") { return folder(id) }
        // A map center (c=), arbitrary URL coordinates, or a broad search term
        // does not identify a selected place or a complete address.
        return nil
    }
}
