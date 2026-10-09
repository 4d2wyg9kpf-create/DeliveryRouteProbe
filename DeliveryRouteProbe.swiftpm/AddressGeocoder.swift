import Foundation
import CoreLocation
import Contacts

private struct AddressCandidate: Codable {
    var address: String
    var countryCode: String
    var coordinate: TMapCoordinate
    var savedAt: Date
}

// The address comes from the selected Naver detail document. Apple results are
// accepted only for that full building address, not a city or street centroid.
@MainActor
final class AddressGeocoder {
    static let shared = AddressGeocoder()
    private let geocoder = CLGeocoder()
    private var cache: [String: [AddressCandidate]] = [:]
    private var busy = false
    private var nextRequest = Date.distantPast
    private var blockedUntil = Date.distantPast
    private init() {
        if let url = try? Self.cacheURL(), let data = try? Data(contentsOf: url), data.count <= 4_000_000,
           let saved = try? JSONDecoder().decode([String: [AddressCandidate]].self, from: data) { cache = saved }
    }
    private static func cacheURL() throws -> URL {
        let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("RouteProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("address-coordinate-cache.json")
    }
    func resolve(_ capture: NaverPlaceCapture) async throws -> NaverPlaceCapture {
        let address = capture.preferredAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw PlannerFailure.message("선택한 장소의 전체 주소를 먼저 읽어 주세요.") }
        if let saved = cache[address], saved.allSatisfy({ Date().timeIntervalSince($0.savedAt) < 30 * 86400 }) {
            return try merge(capture, saved)
        }
        while busy { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 200_000_000) }
        guard Date() >= blockedUntil else { throw PlannerFailure.message("주소 변환 서버가 잠시 제한했습니다. 잠시 후 다시 시도해 주세요.") }
        busy = true
        defer { busy = false }
        let delay = nextRequest.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        nextRequest = Date().addingTimeInterval(2)
        let candidates: [AddressCandidate]
        do {
            let marks = try await geocoder.geocodeAddressString(address, in: nil, preferredLocale: Locale(identifier: "ko_KR"))
            try Task.checkCancellation()
            candidates = marks.compactMap { mark in
                guard let location = mark.location, let postal = mark.postalAddress else { return nil }
                let street = (mark.thoroughfare != nil && mark.subThoroughfare != nil) ? mark.thoroughfare! + " " + mark.subThoroughfare! : postal.street
                let formatted = [postal.state, postal.city, postal.subLocality, street].filter { !$0.isEmpty }.joined(separator: " ")
                return AddressCandidate(address: formatted, countryCode: mark.isoCountryCode ?? "", coordinate: TMapCoordinate(longitude: location.coordinate.longitude, latitude: location.coordinate.latitude), savedAt: Date())
            }
        } catch is CancellationError { geocoder.cancelGeocode(); throw CancellationError() }
        catch {
            if (error as NSError).domain == kCLErrorDomain && (error as NSError).code == CLError.Code.network.rawValue { blockedUntil = Date().addingTimeInterval(60) }
            throw PlannerFailure.message("주소를 좌표로 변환하지 못했습니다. \(error.localizedDescription)")
        }
        let result = try merge(capture, candidates)
        cache[address] = candidates
        if cache.count > 1000 { cache = Dictionary(uniqueKeysWithValues: cache.sorted { ($0.value.first?.savedAt ?? .distantPast) > ($1.value.first?.savedAt ?? .distantPast) }.prefix(1000).map { ($0.key, $0.value) }) }
        if let url = try? Self.cacheURL(), let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
        return result
    }
    private func merge(_ capture: NaverPlaceCapture, _ candidates: [AddressCandidate]) throws -> NaverPlaceCapture {
        try NaverPlaceBridge.call("geocode", ["capture": try TMapBridge.object(capture), "candidates": try candidates.map { try TMapBridge.object($0) }], as: NaverPlaceCapture.self)
    }
}
