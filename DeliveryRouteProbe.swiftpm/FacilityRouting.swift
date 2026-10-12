import Foundation
import CoreFoundation

enum FacilityRouteProvider: String, Codable, CaseIterable, Identifiable {
    case naverAPI, kakaoAPI, naverWeb, kakaoWeb
    var id: String { rawValue }
    var title: String {
        switch self { case .naverAPI: return "네이버 API"; case .kakaoAPI: return "카카오 API"; case .naverWeb: return "네이버 웹"; case .kakaoWeb: return "카카오 웹" }
    }
    var isWeb: Bool { self == .naverWeb || self == .kakaoWeb }
    func supports(_ mode: FacilityTransport) -> Bool { mode == .car || isWeb }
}
enum FacilityTransport: String, Codable, CaseIterable, Identifiable {
    case car, walk, transit
    var id: String { rawValue }
    var title: String { switch self { case .car: return "자동차"; case .walk: return "도보"; case .transit: return "대중교통" } }
    var legacyMode: KakaoRouteMode { switch self { case .car: return .car; case .walk: return .walk; case .transit: return .transit } }
}
enum FacilityRouteCriterion: String, Codable, CaseIterable, Identifiable {
    case time, distance, recommended
    var id: String { rawValue }
    var title: String { switch self { case .time: return "빠른 길"; case .distance: return "거리 우선"; case .recommended: return "추천" } }
    var kakaoPriority: String { self == .distance ? "DISTANCE" : "TIME" }
    var naverOption: String { self == .time ? "trafast" : "traoptimal" }
}
struct FacilityRouteRequest {
    var id = UUID().uuidString
    var provider: FacilityRouteProvider
    var transport: FacilityTransport
    var criterion: FacilityRouteCriterion
    var origin: RouteEndpoint
    var destination: RouteEndpoint
    var departure: Date?
    func validate(now: Date = Date()) throws {
        guard provider.supports(transport), KakaoRouteAPI.valid(origin.coordinate), KakaoRouteAPI.valid(destination.coordinate),
              origin.id != destination.id, !origin.name.isEmpty, !destination.name.isEmpty else { throw PlannerFailure.message("길찾기 제공자·출발지·목적지·좌표를 확인하세요.") }
        if provider == .kakaoAPI && criterion == .recommended { throw PlannerFailure.message("카카오 API는 빠른 길 또는 거리 우선을 선택하세요.") }
        if provider == .naverAPI && criterion == .distance { throw PlannerFailure.message("네이버 API는 최단거리 옵션을 제공하지 않습니다. 빠른 길·추천 또는 네이버 웹을 선택하세요.") }
        if let departure {
            guard transport == .car, provider != .naverAPI, departure.timeIntervalSince1970.isFinite, departure.timeIntervalSince(now) >= 60 else { throw PlannerFailure.message("출발시각 지정은 자동차에서 지원합니다. 미래 시각과 제공자의 지원 여부를 확인하세요.") }
            if provider == .naverWeb {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
                guard calendar.component(.minute, from: departure) % 10 == 0 else { throw PlannerFailure.message("네이버 웹은 출발시각을 10분 단위로 지정합니다.") }
            }
            if provider == .kakaoWeb {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
                guard calendar.component(.minute, from: departure) % 5 == 0, departure.timeIntervalSince(now) < 365 * 86400 else { throw PlannerFailure.message("카카오 웹은 5분 단위, 오늘부터 1년 이내로 지정하세요.") }
            }
        }
    }
    var webURL: URL {
        if provider == .kakaoWeb {
            let mode = transport == .transit ? "traffic" : transport.rawValue
            func point(_ endpoint: RouteEndpoint) -> String {
                let name = endpoint.name.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? "지점"
                return "\(name),\(endpoint.coordinate.latitude),\(endpoint.coordinate.longitude)"
            }
            return URL(string: "https://map.kakao.com/link/by/\(mode)/\(point(origin))/\(point(destination))")!
        }
        if transport != .car {
            var c = URLComponents(); c.scheme = "https"; c.host = "m.map.naver.com"; c.path = "/route.nhn"
            c.queryItems = [URLQueryItem(name: "menu", value: "route"), URLQueryItem(name: "sname", value: origin.name),
                URLQueryItem(name: "sx", value: String(origin.coordinate.longitude)), URLQueryItem(name: "sy", value: String(origin.coordinate.latitude)),
                URLQueryItem(name: "ename", value: destination.name), URLQueryItem(name: "ex", value: String(destination.coordinate.longitude)), URLQueryItem(name: "ey", value: String(destination.coordinate.latitude)),
                URLQueryItem(name: "pathType", value: transport == .walk ? "3" : "1"), URLQueryItem(name: "showMap", value: "false")]
            return c.url!
        }
        func point(_ endpoint: RouteEndpoint) -> String {
            let p = Self.mercator(endpoint.coordinate)
            let name = endpoint.name.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? "지점"
            return "\(p[0]),\(p[1]),\(name),,SIMPLE_POI"
        }
        return URL(string: "https://map.naver.com/p/directions/\(point(origin))/\(point(destination))/-/car")!
    }
    static func mercator(_ c: TMapCoordinate) -> [Double] {
        let r = 6_378_137.0
        return [c.longitude * .pi / 180 * r, log(tan(.pi / 4 + c.latitude * .pi / 360)) * r]
    }
    var scriptArguments: [String: Any] {
        var result: [String: Any] = ["id": id, "provider": provider.rawValue, "mode": transport.rawValue, "criterion": criterion.rawValue,
            "origin": ["name": origin.name, "longitude": origin.coordinate.longitude, "latitude": origin.coordinate.latitude],
            "destination": ["name": destination.name, "longitude": destination.coordinate.longitude, "latitude": destination.coordinate.latitude]]
        if let departure {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
            let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: departure)
            result["departure"] = ["year": p.year!, "month": p.month!, "day": p.day!, "hour": p.hour!, "minute": p.minute!, "key": KakaoRouteAPI.departure(departure)] as [String: Any]
        }
        return result
    }
}
struct FacilityWebCandidate: Decodable {
    var label: String
    var distanceMeters: Int?
    var durationSeconds: Int
    var raw: String
    var referenceDistanceMeters: Int?
}
struct FacilityWebReply: Decodable {
    var status: String
    var message: String?
    var requestID: String?
    var pageURL: String?
    var timeBasis: String?
    var departureKey: String?
    var candidates: [FacilityWebCandidate]?
}
enum FacilityRouteRecords {
    static func web(_ reply: FacilityWebReply, request: FacilityRouteRequest, now: Date = Date()) throws -> [KakaoDistanceRecord] {
        guard request.provider.isWeb, reply.status == "ready", reply.requestID == request.id, let url = reply.pageURL.flatMap(URL.init(string:)), url.scheme == "https",
              (request.provider == .naverWeb ? ["map.naver.com", "m.map.naver.com", "m.search.naver.com"] : ["map.kakao.com", "m.map.kakao.com"]).contains(url.host ?? ""),
              let candidates = reply.candidates, !candidates.isEmpty, candidates.count <= 100 else { throw PlannerFailure.message("요청한 웹 경로와 판독 결과가 일치하지 않습니다.") }
        if let departure = request.departure {
            guard reply.departureKey == KakaoRouteAPI.departure(departure), reply.timeBasis == "scheduled" else { throw PlannerFailure.message("웹 화면의 출발 날짜·시각을 확인하지 못했습니다. 현재 출발 결과로 저장하지 않습니다.") }
        } else { guard reply.timeBasis == "current" else { throw PlannerFailure.message("웹 경로의 출발 기준이 다릅니다.") } }
        let selected: [FacilityWebCandidate]
        if request.transport == .walk && request.criterion != .recommended {
            selected = [candidates.min { a, b in request.criterion == .distance ? (a.distanceMeters ?? Int.max) < (b.distanceMeters ?? Int.max) : a.durationSeconds < b.durationSeconds }!]
        } else { selected = candidates }
        return try selected.map { c in
            guard (0...20_000_000).contains(c.durationSeconds), c.distanceMeters.map({ (0...20_000_000).contains($0) }) ?? true,
                  c.referenceDistanceMeters.map({ (0...20_000_000).contains($0) }) ?? true,
                  !c.raw.isEmpty, c.raw.utf8.count <= 20_000 else { throw PlannerFailure.message("웹 거리·시간의 단위와 원문을 확인하세요.") }
            var r = KakaoDistanceRecord(origin: request.origin, destination: request.destination, mode: request.transport.legacyMode,
                priority: request.criterion.rawValue, departureTime: request.departure.map(KakaoRouteAPI.departure), queriedAt: now,
                distanceMeters: c.distanceMeters, durationSeconds: c.durationSeconds, alternative: c.label, issue: nil, landingURL: url.absoluteString)
            r.provider = request.provider.rawValue; r.timeBasis = reply.timeBasis; r.rawSummary = c.raw; r.referenceDistanceMeters = c.referenceDistanceMeters
            return r
        }
    }
    static func naver(_ body: [String: Any], request: FacilityRouteRequest, now: Date = Date()) throws -> [KakaoDistanceRecord] {
        guard body["code"] as? Int == 0, let route = body["route"] as? [String: Any], let rows = route[request.criterion.naverOption] as? [[String: Any]], !rows.isEmpty else { throw PlannerFailure.message(body["message"] as? String ?? "네이버 자동차 경로가 없습니다.") }
        func integer(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue, (0...100_000_000).contains(n.doubleValue) else { return nil }; return n.intValue
        }
        return try rows.map { row in
            guard let s = row["summary"] as? [String: Any], let distance = integer(s["distance"]), let millis = integer(s["duration"]) else { throw PlannerFailure.message("네이버 응답에 거리·시간이 없습니다.") }
            func matches(_ name: String, _ point: TMapCoordinate) -> Bool {
                guard let info = s[name] as? [String: Any], let location = info["location"] as? [Double], location.count == 2 else { return false }
                return abs(location[0] - point.longitude) < 0.00001 && abs(location[1] - point.latitude) < 0.00001
            }
            guard matches("start", request.origin.coordinate), matches("goal", request.destination.coordinate) else { throw PlannerFailure.message("네이버 응답의 출발·도착 좌표가 다릅니다.") }
            var r = KakaoDistanceRecord(origin: request.origin, destination: request.destination, mode: .car, priority: request.criterion.naverOption,
                queriedAt: now, distanceMeters: distance, durationSeconds: Int(ceil(Double(millis) / 1000)), alternative: request.criterion.title, issue: nil)
            r.provider = FacilityRouteProvider.naverAPI.rawValue; r.timeBasis = "current"
            return r
        }
    }
}
