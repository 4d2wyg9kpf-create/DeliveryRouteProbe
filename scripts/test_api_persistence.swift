// Synthetic model dependencies only. Both shipped stores, archive, quota engines
// and native request gates compile below. No live credentials or network calls.
import Foundation

struct MapRoutePoint: Codable { var token: String; var name: String }
struct TestAccess: Codable { var curbConfirmed = false; var curbPoint: MapRoutePoint? }
struct TestVisit: Codable {
    var id = "fixture-stop"
    var name = "가상 거래처"
    var kind = "delivery"
    var serviceMinutes = 5
    var arrivalWindowsText = ""
    var avoidWindowsText = ""
    var allowEarlyArrival = true
    var tmapCoordinate: TMapCoordinate? = TMapCoordinate(longitude: 127.4, latitude: 36.3)
    var naverPlace: NaverPlaceCapture?
}
struct DeliveryLeg: Codable { var id: String }
struct DeliveryPlan: Codable {
    var schemaVersion = 3
    var planDate = "2026-10-09"
    var startMinute = 480
    var originName = "가상 출발지"
    var returnToOrigin = true
    var visits = [TestVisit()]
    var destination: TestVisit?
    var tmapOrigin: TMapCoordinate? = TMapCoordinate(longitude: 127.39, latitude: 36.31)
    var naverOrigin: NaverPlaceCapture?
    func access(_ id: String) -> TestAccess? { nil }
}
@MainActor final class PlannerStore {
    var plan = DeliveryPlan()
    func replacePlan(_ next: DeliveryPlan) { plan = next }
    func calculate() {}
}
enum PlannerFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
private func require(_ value: Bool, _ message: String) throws { if !value { throw PlannerFailure.message(message) } }
private func json(_ value: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: value) as! [String: Any] }
private func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

@MainActor private final class Fixture {
    let kind: APIProtectedStateFile.Kind
    var primary: Data?
    var protected: Data?
    var primaryReadFails = false
    var primaryWriteFails = false
    var protectedReadFails = false
    var protectedWriteFails = false
    var protectedWrites = 0
    var heads = 0
    var charged = 0
    var requestKeyMatches = true
    init(_ kind: APIProtectedStateFile.Kind = .naverAPI, legacy: Bool = false) throws {
        self.kind = kind
        if kind == .tmap {
            var options = TMapOptions(); options.truckRouting = false; options.truckHeight = 250
            primary = try bytes(["appKey": "fixture-tmap-key", "freePlanConfirmed": true,
                "options": try TMapBridge.object(options), "ledger": ["version": 1, "accounts": [:]]])
        } else {
            var value: [String: Any] = ["version": 1, "searchID": "fixture-search-id", "searchSecret": "fixture-search-secret",
                "mapsID": "fixture-maps-id", "mapsSecret": "fixture-maps-secret", "mapsFreeConfirmed": true,
                "ledger": ["version": 1, "accounts": [:]]]
            if !legacy { value["searchProvider"] = "hub"; value["searchFreeConfirmed"] = true }
            primary = try bytes(value)
        }
    }
    func archive() -> APICredentialArchive {
        APICredentialArchive(readPrimary: {
            if self.primaryReadFails { throw APICredentialStorageError.unavailable }; return self.primary
        }, writePrimary: {
            if self.primaryWriteFails { throw APICredentialStorageError.unavailable }; self.primary = $0
        }, readProtected: {
            if self.protectedReadFails { throw APICredentialStorageError.unavailable }; return self.protected
        }, writeProtected: {
            if self.protectedWriteFails { throw APICredentialStorageError.unavailable }
            self.protectedWrites += 1; self.protected = $0
        }, validate: {
            if self.kind == .tmap { try TMapStore.validateSavedState($0) }
            else { try NaverAPIStore.validateSavedState($0) }
        })
    }
    func naver(_ archive: APICredentialArchive) -> NaverAPIStore {
        NaverAPIStore(read: { try archive.read() }, write: { try archive.write($0) }, transport: { try await self.respond($0) })
    }
    func tmap(_ archive: APICredentialArchive) -> TMapStore {
        TMapStore(read: { try archive.read() }, write: { try archive.write($0) }, transport: { try await self.respond($0) })
    }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let isHead = request.httpMethod == "HEAD"
        var body: [String: Any] = [:]
        if isHead { heads += 1 }
        else {
            charged += 1
            try require(try used() > 0, "reservation was not persisted before dispatch")
            if kind == .tmap {
                requestKeyMatches = request.value(forHTTPHeaderField: "appKey") == "fixture-tmap-key"
                body = ["error": ["message": "fixture bad input"]]
            } else if request.url?.host == "maps.apigw.ntruss.com" {
                requestKeyMatches = request.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY-ID") == "fixture-maps-id" && request.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY") == "fixture-maps-secret"
                body = ["status": "OK", "addresses": [["roadAddress": "대전광역시 중구 유천로 35", "jibunAddress": "대전 중구 유천동 100", "x": "127.398", "y": "36.316"]]]
            } else {
                let legacy = request.url?.host == "openapi.naver.com"
                requestKeyMatches = request.value(forHTTPHeaderField: legacy ? "X-Naver-Client-Id" : "X-NCP-APIGW-API-KEY-ID") == "fixture-search-id" && request.value(forHTTPHeaderField: legacy ? "X-Naver-Client-Secret" : "X-NCP-APIGW-API-KEY") == "fixture-search-secret"
                body = ["items": [["title": "가상 거래처", "roadAddress": "대전광역시 중구 유천로 35", "address": "대전 중구 유천동 100", "category": "배송", "mapx": "1273980000", "mapy": "363160000"]]]
            }
        }
        return (try bytes(body), HTTPURLResponse(url: request.url!, statusCode: !isHead && kind == .tmap ? 400 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Date": "Fri, 09 Oct 2026 14:50:00 GMT", "Age": "0"])!)
    }
    func used() throws -> Int {
        let value = try json(protected ?? primary!)
        let ledger = value["ledger"] as! [String: Any], accounts = ledger["accounts"] as! [String: [String: Any]]
        if kind == .tmap {
            return accounts.values.reduce(0) { count, account in
                count + (account["buckets"] as! [String: [String: Any]]).values.reduce(0) { $0 + ($1["used"] as! Int) }
            }
        }
        return accounts.values.reduce(0) { $0 + ($1["used"] as! Int) }
    }
}

@main struct APIPersistenceTests {
    @MainActor static func main() async {
        var checks: [[String: Any]] = []
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); checks.append(["name": name, "passed": true]) }
            catch { checks.append(["name": name, "passed": false, "error": error.localizedDescription]) }
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { return }; throw PlannerFailure.message("expected rejection")
        }
        func waitForTMap(_ store: TMapStore) async throws {
            for _ in 0..<400 {
                if !store.isOptimizing && !store.isRefreshing { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw PlannerFailure.message("fixture task did not finish")
        }
        await test("First install has no synthetic keys or quota reset errors") {
            let f = try Fixture(); f.primary = nil
            let s = f.naver(f.archive())
            try require(!s.hasSearchKeys && !s.hasMapsKeys && s.errorMessage == nil && f.protected == nil, "bad first install")
        }
        await test("0.14.1 Keychain-only HUB and Maps keys migrate before any API call") {
            let f = try Fixture(), s = f.naver(f.archive())
            try require(s.hasSearchKeys && s.hasMapsKeys && s.searchProvider == .hub && s.searchFreeConfirmed && s.mapsFreeConfirmed, "settings lost")
            try require(f.protected != nil && f.primary == f.protected && f.charged == 0 && f.heads == 0, "migration missing or network used")
        }
        await test("Older Developers key format migrates with original host and credentials") {
            let f = try Fixture(legacy: true), s = f.naver(f.archive())
            try require(s.searchProvider == .legacy && !s.searchFreeConfirmed, "legacy provider changed")
            _ = try await s.search("가상 거래처")
            try require(f.requestKeyMatches && f.charged == 1, "legacy credentials lost")
            let restarted = f.naver(f.archive())
            try require(restarted.searchProvider == .legacy && restarted.quotas["search"]?.used == 1, "legacy usage lost")
        }
        await test("HUB update/restart restores exact key pair and both quota counters") {
            let f = try Fixture(), s = f.naver(f.archive())
            _ = try await s.search("가상 거래처")
            let restarted = f.naver(f.archive())
            try require(restarted.quotas["search"]?.used == 1 && restarted.quotas["searchMonth"]?.used == 1, "quota reset on update")
            _ = try await restarted.search("가상 거래처")
            try require(f.requestKeyMatches && restarted.quotas["search"]?.used == 2 && restarted.quotas["searchMonth"]?.used == 2, "key pair or quota lost")
        }
        await test("Changed signing access group recovers HUB and Maps from protected file") {
            let f = try Fixture(); _ = f.naver(f.archive()); f.primary = nil; f.primaryReadFails = true; f.primaryWriteFails = true
            let s = f.naver(f.archive())
            try require(s.hasSearchKeys && s.hasMapsKeys && s.errorMessage == nil, "backup recovery failed")
            _ = try await s.search("가상 거래처")
            try require(f.requestKeyMatches && s.quotas["search"]?.used == 1 && s.quotas["searchMonth"]?.used == 1, "fallback lost keys/counters")
        }
        await test("Maps update retains Geocoding credentials and account-wide monthly balance") {
            let f = try Fixture(), a = f.archive(), s = f.naver(a)
            _ = try await s.address("대전광역시 중구 유천로 35", name: "가상 거래처")
            let restarted = f.naver(f.archive())
            try require(f.requestKeyMatches && restarted.mapsFreeConfirmed && restarted.quotas["maps"]?.used == 1, "Maps key/quota lost")
        }
        await test("Blank settings inputs preserve all four NAVER key values") {
            let f = try Fixture(), s = f.naver(f.archive())
            try require(s.saveSettings(searchID: "", searchSecret: "", mapsID: "", mapsSecret: "", freeConfirmed: true, searchProvider: .hub, searchFreeConfirmed: true), "blank save failed")
            await Task.yield()
            let values = try json(f.protected!)
            try require(values["searchID"] as? String == "fixture-search-id" && values["searchSecret"] as? String == "fixture-search-secret" && values["mapsID"] as? String == "fixture-maps-id" && values["mapsSecret"] as? String == "fixture-maps-secret", "blank erased a key")
        }
        await test("Newly edited NAVER keys are selected over stale Keychain after restart") {
            let f = try Fixture(), s = f.naver(f.archive()), old = f.primary
            try require(s.saveSettings(searchID: "fixture-replacement-id", searchSecret: "fixture-replacement-secret", mapsID: "", mapsSecret: "", freeConfirmed: true, searchProvider: .hub, searchFreeConfirmed: true), "replacement failed")
            await Task.yield(); f.primary = old
            let a = f.archive(), restored = try json(a.read()!)
            try require(restored["searchID"] as? String == "fixture-replacement-id" && restored["searchSecret"] as? String == "fixture-replacement-secret" && f.primary == f.protected, "stale key selected")
        }
        await test("TMap legacy key, truck options and free confirmation migrate intact") {
            let f = try Fixture(.tmap), s = f.tmap(f.archive())
            try require(s.hasAppKey && s.freePlanConfirmed && !s.options.truckRouting && s.options.truckHeight == 250 && f.protected == f.primary, "TMap settings lost")
        }
        await test("TMap blank key input keeps saved key and latest truck options") {
            let f = try Fixture(.tmap), s = f.tmap(f.archive())
            var options = s.options; options.truckHeight = 270
            s.saveSettings(appKey: "", freeConfirmed: true, options: options)
            await Task.yield(); try await waitForTMap(s)
            let restarted = f.tmap(f.archive()), values = try json(f.protected!)
            try require(values["appKey"] as? String == "fixture-tmap-key" && restarted.hasAppKey && restarted.options.truckHeight == 270, "TMap key erased")
        }
        await test("Edited TMap key persists on next launch instead of the previous value") {
            let f = try Fixture(.tmap), s = f.tmap(f.archive())
            s.saveSettings(appKey: "fixture-new-tmap-key", freeConfirmed: true, options: s.options)
            await Task.yield(); try await waitForTMap(s)
            let restarted = f.tmap(f.archive()), values = try json(f.protected!)
            try require(restarted.hasAppKey && values["appKey"] as? String == "fixture-new-tmap-key", "updated TMap key lost")
        }
        await test("TMap failed POST reservation survives update and signing-group loss") {
            let f = try Fixture(.tmap), s = f.tmap(f.archive())
            s.optimize(plan: DeliveryPlan()); try await waitForTMap(s)
            try require(f.charged == 1 && f.requestKeyMatches && s.quota(for: 1)?.used == 1, "TMap reserve or credential failed")
            f.primary = nil; f.primaryReadFails = true; f.primaryWriteFails = true
            let restarted = f.tmap(f.archive())
            try require(restarted.hasAppKey && restarted.quota(for: 1)?.used == 1 && restarted.quota(for: 1)?.remaining == 49, "update refunded TMap usage")
        }
        await test("TMap exhaustion cannot be cleared by restarting or losing Keychain") {
            let f = try Fixture(.tmap), s = f.tmap(f.archive())
            await s.refreshClock(); s.raiseUsed(apiID: 10, used: 50)
            f.primary = nil; f.primaryReadFails = true; f.primaryWriteFails = true
            let restarted = f.tmap(f.archive()); restarted.optimize(plan: DeliveryPlan()); try await waitForTMap(restarted)
            try require(f.charged == 0 && restarted.quota(for: 1)?.remaining == 0, "exhausted bucket dispatched after update")
        }
        await test("Stale Keychain never rolls back a newer protected reservation") {
            let f = try Fixture(), s = f.naver(f.archive()), stale = f.primary
            _ = try await s.search("가상 거래처"); f.primary = stale
            let restarted = f.naver(f.archive())
            try require(restarted.quotas["search"]?.used == 1 && restarted.quotas["searchMonth"]?.used == 1 && f.primary == f.protected, "stale quota selected")
        }
        await test("Newer Keychain restores a stale protected file without losing usage") {
            let f = try Fixture(), s = f.naver(f.archive()), stale = f.protected
            _ = try await s.search("가상 거래처"); f.protected = stale
            let restarted = f.naver(f.archive())
            try require(restarted.quotas["search"]?.used == 1 && f.protected == f.primary, "newer primary ignored")
        }
        await test("Keychain write failure keeps durable reservations and remains usable") {
            let f = try Fixture(), s = f.naver(f.archive()); f.primaryWriteFails = true
            _ = try await s.search("가상 거래처")
            let restarted = f.naver(f.archive()); _ = try await restarted.search("가상 거래처")
            try require(f.charged == 2 && restarted.quotas["search"]?.used == 2 && restarted.quotas["searchMonth"]?.used == 2, "Keychain fallback lost usage")
        }
        await test("Protected-file write failure prevents NAVER billable dispatch") {
            let f = try Fixture(), s = f.naver(f.archive()); f.protectedWriteFails = true
            do { _ = try await s.search("가상 거래처") } catch {}
            try require(f.charged == 0 && (try f.used()) == 0, "unsaved NAVER request dispatched")
        }
        await test("Protected-file write failure prevents TMap billable dispatch") {
            let f = try Fixture(.tmap), s = f.tmap(f.archive()); f.protectedWriteFails = true
            s.optimize(plan: DeliveryPlan()); try await waitForTMap(s)
            try require(f.charged == 0 && (try f.used()) == 0, "unsaved TMap request dispatched")
        }
        await test("Unreadable protected file cannot be replaced with older Keychain") {
            let f = try Fixture(), a = f.archive(); _ = try a.read(); let original = f.protected
            f.protectedReadFails = true
            try rejects { _ = try f.archive().read() }
            try require(original == f.protected, "unreadable record overwritten")
        }
        await test("Malformed existing record blocks calls instead of creating empty state") {
            let f = try Fixture(); _ = try f.archive().read(); f.protected = Data("broken".utf8)
            let s = f.naver(f.archive())
            do { _ = try await s.search("가상 거래처") } catch {}
            try require(s.errorMessage != nil && f.charged == 0, "corruption reset quota")
        }
        await test("Modified credential payload fails checksum verification") {
            let f = try Fixture(); _ = try f.archive().read()
            var value = try json(f.protected!); value["searchID"] = "fixture-tampered"; f.protected = try bytes(value)
            try rejects { _ = try f.archive().read() }
        }
        await test("Equal revisions with differing valid states fail closed") {
            let f = try Fixture(), g = try Fixture(); _ = try f.archive().read()
            var value = try json(g.primary!); value["searchID"] = "fixture-different"; g.primary = try bytes(value); _ = try g.archive().read()
            f.protected = g.protected
            try rejects { _ = try f.archive().read() }
        }
        await test("Unknown state version is never migrated as a valid credential record") {
            let f = try Fixture(); var value = try json(f.primary!); value["version"] = 999; f.primary = try bytes(value)
            try rejects { _ = try f.archive().read() }
            try require(f.protected == nil, "invalid version copied")
        }
        await test("Legacy decoder still reads top-level Keychain state after migration") {
            struct OldState: Decodable { var searchID: String; var searchSecret: String; var mapsID: String; var mapsSecret: String }
            let f = try Fixture(); _ = try f.archive().read()
            let decoded = try JSONDecoder().decode(OldState.self, from: f.primary!)
            try require(decoded.searchID == "fixture-search-id" && decoded.searchSecret == "fixture-search-secret" && decoded.mapsID == "fixture-maps-id" && decoded.mapsSecret == "fixture-maps-secret", "old schema broken")
        }
        await test("Actual protected file is atomic, private, excluded from backup and outside Documents") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-persistence-fixture-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = try APIProtectedStateFile(.naverAPI, directory: directory), f = try Fixture()
            let a = APICredentialArchive(readPrimary: { f.primary }, writePrimary: { f.primary = $0 }, readProtected: { try file.read() }, writeProtected: { try file.write($0) }, validate: { try NaverAPIStore.validateSavedState($0) })
            _ = try a.read(); try require(try file.read() == f.primary, "file bytes differ")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "file permissions not private")
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            try require(values.isExcludedFromBackup == true, "credential file included in backup")
            let live = try APIProtectedStateFile(.tmap)
            try require(live.url.path.contains("Application Support/DeliveryRouteSecureState/tmap.state") && !live.url.path.contains("/Documents/"), "credential location exposed")
        }
        let result: [String: Any] = ["passed": checks.filter { $0["passed"] as? Bool == true }.count, "total": checks.count,
            "checks": checks, "native_stores_tested": true, "live_api_calls": false, "physical_device_update_tested": false]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}
