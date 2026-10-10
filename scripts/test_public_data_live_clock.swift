import Foundation

// Compile the shipped store without replacing its network transport. This test
// has no API key and makes only public, credential-free HTTPS clock requests.
struct TMapCoordinate: Codable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
private enum LiveClockFailure: Error { case failed(String) }

@main struct PublicDataLiveClockCheck {
    @MainActor static func main() async throws {
        var saved: Data?
        let store = PublicDataStore(read: { saved }, write: { saved = $0 }, transport: nil)
        await store.refreshClock()
        if let error = store.errorMessage { throw LiveClockFailure.failed(error) }
        guard let saved, let state = try JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let millis = state["lastTrustedMillis"] as? Double,
              abs(millis / 1_000 - Date().timeIntervalSince1970) < 120,
              state["serviceKey"] as? String == "", !store.hasKey,
              store.quotas.allSatisfy({ $0.used == 0 && $0.resetAt != nil }) else {
            throw LiveClockFailure.failed("Live HTTPS clock was not verified without API credentials or quota use")
        }
        print("PASS shipped URLSession verifies live HTTPS clock without an API key or billable API request")
        print("Public data live clock checks: 1/1 passed")
    }
}
