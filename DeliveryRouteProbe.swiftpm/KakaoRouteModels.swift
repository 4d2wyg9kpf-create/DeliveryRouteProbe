import Foundation
import CoreFoundation

enum KakaoRouteMode: String, Codable, CaseIterable, Identifiable {
    case walk, transit, car, origins, destinations, future
    var id: String { rawValue }
    var title: String {
        switch self { case .walk: return "도보 · 카카오맵"; case .transit: return "대중교통 · 카카오맵"; case .car: return "자동차 · 카카오내비"; case .origins: return "다중 출발지 · 카카오내비"; case .destinations: return "다중 목적지 · 카카오내비"; case .future: return "미래 운행 · 카카오내비" }
    }
    var dailyLimit: Int { switch self { case .car: return 10_000; case .future: return 5_000; default: return 1_000 } }
    var isBatch: Bool { self == .origins || self == .destinations }
    var isMap: Bool { self == .walk || self == .transit }
}
struct RouteEndpoint: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var address: String
    var coordinate: TMapCoordinate
}
struct KakaoDistanceRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var origin: RouteEndpoint
    var destination: RouteEndpoint
    var mode: KakaoRouteMode
    var priority: String
    var departureTime: String?
    var queriedAt: Date
    var distanceMeters: Int?
    var durationSeconds: Int?
    var alternative: String
    var issue: String?
    var landingURL: String?
    func matches(_ endpoints: [RouteEndpoint]) -> Bool {
        endpoints.contains { $0.id == origin.id && $0.coordinate == origin.coordinate } && endpoints.contains { $0.id == destination.id && $0.coordinate == destination.coordinate }
    }
}
enum KakaoRouteAPI {
    static func departure(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Seoul"); f.dateFormat = "yyyyMMddHHmm"; return f.string(from: date)
    }
    static func request(mode: KakaoRouteMode, origin: RouteEndpoint, destinations: [RouteEndpoint], key: String,
                        priority: String, radius: Int = 10_000, departure: Date? = nil, now: Date = Date()) throws -> URLRequest {
        guard !key.isEmpty, destinations.count >= 1, destinations.count <= (mode.isBatch ? 30 : 1),
              ["TIME", "DISTANCE"].contains(priority), (1...10_000).contains(radius),
              Set(destinations.map(\.id)).count == destinations.count,
              ([origin] + destinations).allSatisfy({ valid($0.coordinate) && !$0.id.isEmpty && $0.id.utf8.count <= 300 }) else { throw PlannerFailure.message("조회할 좌표·개수·기준을 확인하세요.") }
        let end = destinations[0]
        var c = URLComponents(); c.scheme = "https"; c.host = mode.isMap ? "dapi.kakao.com" : "apis-navi.kakaomobility.com"
        switch mode {
        case .walk: c.path = "/v2/routing/walk"
        case .transit: c.path = "/v2/routing/publictraffic"
        case .car: c.path = "/v1/directions"
        case .future: c.path = "/v1/future/directions"
        case .origins: c.path = "/v1/origins/directions"
        case .destinations: c.path = "/v1/destinations/directions"
        }
        if mode.isMap {
            c.queryItems = [URLQueryItem(name: "start_x", value: String(origin.coordinate.longitude)), URLQueryItem(name: "start_y", value: String(origin.coordinate.latitude)),
                URLQueryItem(name: "end_x", value: String(end.coordinate.longitude)), URLQueryItem(name: "end_y", value: String(end.coordinate.latitude)),
                URLQueryItem(name: "s_name", value: origin.name), URLQueryItem(name: "e_name", value: end.name), URLQueryItem(name: "input_coord", value: "WGS84"), URLQueryItem(name: "output_coord", value: "WGS84")]
            if mode == .walk { c.queryItems?.append(URLQueryItem(name: "route_mode", value: "SHORTEST")) }
        } else if !mode.isBatch {
            func point(_ p: RouteEndpoint) -> String { "\(p.coordinate.longitude),\(p.coordinate.latitude)" }
            c.queryItems = [URLQueryItem(name: "origin", value: point(origin)), URLQueryItem(name: "destination", value: point(end)), URLQueryItem(name: "priority", value: priority)]
            if mode == .future {
                guard let departure, departure.timeIntervalSince(now) >= 60 else { throw PlannerFailure.message("미래 운행 출발 시각을 1분 이후로 지정하세요.") }
                c.queryItems?.append(URLQueryItem(name: "departure_time", value: self.departure(departure)))
            }
        }
        var request = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("KakaoAK " + key, forHTTPHeaderField: "Authorization")
        if mode.isBatch {
            func point(_ p: RouteEndpoint, withKey: Bool = false) -> [String: Any] {
                var value: [String: Any] = ["x": p.coordinate.longitude, "y": p.coordinate.latitude]; if withKey { value["key"] = p.id }; return value
            }
            let body: [String: Any] = [mode == .origins ? "destination" : "origin": point(origin),
                mode == .origins ? "origins" : "destinations": destinations.map { point($0, withKey: true) }, "priority": priority, "radius": radius]
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }
    static func valid(_ c: TMapCoordinate) -> Bool { c.longitude.isFinite && c.latitude.isFinite && (124...132).contains(c.longitude) && (32...40).contains(c.latitude) }
    static func parse(_ data: Data, mode: KakaoRouteMode, origin: RouteEndpoint, destinations: [RouteEndpoint], priority: String,
                      departure: Date? = nil, now: Date = Date()) throws -> [KakaoDistanceRecord] {
        guard data.count <= 20_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlannerFailure.message("카카오 응답 형식을 확인하세요.") }
        func integer(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue.rounded() == n.doubleValue, (0...100_000_000).contains(n.doubleValue) else { return nil }; return n.intValue
        }
        func record(_ row: [String: Any], end: RouteEndpoint, alternative: String, map: Bool) throws -> KakaoDistanceRecord {
            let summary = row[map ? "properties" : "summary"] as? [String: Any] ?? [:]
            let code = row["result_code"] as? Int
            let issue: String? = !map && code != 0 ? (row["result_msg"] as? String ?? "경로 탐색 실패 (\(code ?? -1))") : nil
            let distance = integer(summary[map ? "totalDistance" : "distance"]), duration = integer(summary[map ? "totalTime" : "duration"])
            guard issue != nil || (distance != nil && duration != nil) else { throw PlannerFailure.message("거리·시간이 없는 경로 응답입니다.") }
            let a = mode == .origins ? end : origin, b = mode == .origins ? origin : end
            let url = summary["landingUrl"] as? String ?? summary["landingURL"] as? String ?? (object["properties"] as? [String: Any])?["landingURL"] as? String
            return KakaoDistanceRecord(origin: a, destination: b, mode: mode, priority: mode == .walk ? "SHORTEST" : priority,
                departureTime: mode == .future ? departure.map(self.departure) : nil, queriedAt: now, distanceMeters: issue == nil ? distance : nil,
                durationSeconds: issue == nil ? duration : nil, alternative: alternative, issue: issue, landingURL: url)
        }
        if mode.isMap {
            if let status = object["status"] as? String, status != "OK" { throw PlannerFailure.message("카카오 경로 탐색: " + status) }
            if mode == .walk {
                guard let route = object["route"] as? [String: Any] else { throw PlannerFailure.message("도보 경로가 없습니다.") }
                return [try record(route, end: destinations[0], alternative: "도보 최단 경로", map: true)]
            }
        }
        guard let rows = object["routes"] as? [[String: Any]], !rows.isEmpty else { throw PlannerFailure.message("조회된 경로가 없습니다.") }
        if mode.isBatch {
            var seen = Set<String>(), result: [KakaoDistanceRecord] = []
            for row in rows {
                guard let key = row["key"] as? String, seen.insert(key).inserted, let end = destinations.first(where: { $0.id == key }) else { throw PlannerFailure.message("다중 경로의 식별자가 일치하지 않습니다.") }
                result.append(try record(row, end: end, alternative: "", map: false))
            }
            for end in destinations where !seen.contains(end.id) {
                result.append(KakaoDistanceRecord(origin: mode == .origins ? end : origin, destination: mode == .origins ? origin : end,
                    mode: mode, priority: priority, queriedAt: now, alternative: "", issue: "응답 누락"))
            }
            return result
        }
        return try rows.enumerated().map { i, row in try record(row, end: destinations[0], alternative: mode == .transit ? (row["properties"] as? [String: Any])?["type"] as? String ?? "경로 \(i+1)" : "경로 \(i+1)", map: mode == .transit) }
    }
}
