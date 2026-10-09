import Foundation

enum NaverSharedLink {
    enum Kind: Equatable { case place(String), folder(String), short }
    struct Target: Equatable { let kind: Kind; let url: URL }
    enum Failure: LocalizedError {
        case missing, multiple
        var errorDescription: String? {
            switch self {
            case .missing: return "네이버 지도에서 공유한 장소 또는 저장 목록 링크를 붙여넣어 주세요."
            case .multiple: return "한 번에 장소 하나 또는 저장 목록 하나의 링크를 붙여넣어 주세요."
            }
        }
    }
    static func parse(_ text: String) throws -> Target {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let values = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { $0.url }
        let accepted = values.compactMap(target)
        guard !accepted.isEmpty else { throw Failure.missing }
        guard accepted.count == 1 else { throw Failure.multiple }
        return accepted[0]
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
            if let id = match("^/(?:p|v5)/(?:entry|search/[^/]+)/place/([0-9]{1,20})(?:/|$)") { return place(id) }
            if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), ["/", "/p", "/index.nhn", "/local/siteview.nhn"].contains(url.path) {
                let items = parts.queryItems ?? []
                let ids = items.filter { $0.name == "pinId" || $0.name == "code" }.compactMap(\.value)
                if ids.count == 1, ids[0].range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil { return place(ids[0]) }
            }
        }
        if ["m.place.naver.com", "pcmap.place.naver.com", "place.map.naver.com"].contains(host),
           let id = match("^/(?:place|restaurant|cafe|hospital|beauty|hairshop|accommodation)/([0-9]{1,20})(?:/|$)") { return place(id) }
        if host == "pages.map.naver.com", let id = match("^/save-pages/pc/detail-list/([A-Za-z0-9_-]{1,128})(?:/|$)") { return folder(id) }
        // A map center (c=), arbitrary URL coordinates, or a search term does
        // not identify a selected place. Coordinates are read from that place.
        return nil
    }
}
