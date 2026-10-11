import Foundation

// Reads NAVER's HTTP redirect headers. It never creates a browser, executes
// page JavaScript, geocodes a share title, or sends an API credential.
@MainActor
struct NaverSharedLinkResolver {
    enum Result { case pin(NaverPlaceCapture), web(NaverSharedLink.Target) }
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    init(transport: Transport? = nil) { self.transport = transport ?? Self.request }

    func resolve(_ target: NaverSharedLink.Target) async throws -> Result {
        let original = target.url.absoluteString
        var current = target.url
        var visited = Set<String>()
        let deadline = Date().addingTimeInterval(25)
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard visited.insert(current.absoluteString).inserted,
                  let parsed = NaverSharedLink.target(current) else {
                throw PlannerFailure.message("공유 링크의 이동 주소를 확인하지 못했습니다.")
            }
            switch parsed.kind {
            case .place, .folder: return .web(parsed)
            case .mapSelection:
                // Only NAVER's location-share envelope identifies a selected
                // address pin. c=, search centers and arbitrary lat/lng do not.
                let capture = try NaverPlaceBridge.call("sharedPin", [
                    "resolvedURL": current.absoluteString, "sharedURL": original,
                    "now": Date().timeIntervalSince1970 * 1_000
                ], as: NaverPlaceCapture.self)
                return .pin(capture)
            case .short: break
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: min(10, remaining))
            request.httpMethod = "GET"
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let (_, response) = try await transport(request)
            try Task.checkCancellation()
            guard response.url == current, [301, 302, 303, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"), location.utf8.count <= 8_000,
                  let next = URL(string: location, relativeTo: current)?.absoluteURL,
                  next.scheme?.lowercased() == "https", NaverSharedLink.target(next) != nil else {
                throw PlannerFailure.message("공유 링크의 HTTP 응답에서 선택 지점을 찾지 못했습니다. 네이버 지도에서 해당 지점의 공유 링크를 다시 복사해 주세요. 주소의 대표 좌표로 대신 저장하지 않습니다.")
            }
            current = next
        }
        throw PlannerFailure.message("공유 링크의 이동 횟수가 많아 읽기를 중단했습니다.")
    }

    private static func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: NaverShareRedirectStopper(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

private final class NaverShareRedirectStopper: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The first redirect contains the full precision pin. Following it
        // would turn it into a desktop map document and lose that evidence.
        completionHandler(nil)
    }
}
