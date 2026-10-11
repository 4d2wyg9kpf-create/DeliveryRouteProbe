import Foundation

enum ShareCheckFailure: Error { case failed(String) }
func require(_ condition: Bool, _ message: String) throws { if !condition { throw ShareCheckFailure.failed(message) } }
func fails(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw ShareCheckFailure.failed("expected an error")
}
let deviceA = "00000000-0000-0000-0000-000000000001"
let deviceB = "00000000-0000-0000-0000-000000000002"
func usage(_ count: Int, period: String = "2026-10-11", account: String = "fixture-account", domain: String = "public", slot: String = "stores", blocked: Bool = false) -> DeviceShareUsageObservation {
    DeviceShareUsageObservation(domain: domain, account: account, period: period, slot: slot, used: count, limit: 10_000, blocked: blocked, trustedMillis: 1_791_686_400_000)
}
func observedValues(_ replica: DeviceShareReplica) -> [String: Data] { replica.records.compactMapValues(\.value) }

@main struct SharingNativeChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ name: String, _ test: () throws -> Void) throws { try test(); passed += 1; print("PASS \(name)") }
        var a = DeviceShareReplica(deviceID: deviceA), b = DeviceShareReplica(deviceID: deviceB)
        var observedA: [String: Data] = [:], observedB: [String: Data] = [:]
        let first = try DeviceShareCodec.encode("synthetic-customer-a"), second = try DeviceShareCodec.encode("synthetic-customer-b")
        try a.capture(DeviceShareSnapshot(values: ["customer/a": first], usage: [usage(1)]), observed: &observedA)
        try b.capture(DeviceShareSnapshot(values: ["customer/b": second], usage: [usage(2)]), observed: &observedB)
        try check("two devices merge separate edits and sum only their own API calls") {
            var ab = a, ba = b; try ab.merge(b); try ba.merge(a)
            try require(ab.records == ba.records && ab.usage == ba.usage && ab.records.count == 2, "non-commutative merge")
            try require(ab.usage[usage(0).id]?.total == 3, "usage not summed")
        }
        try a.merge(b); try b.merge(a); observedA = observedValues(a); observedB = observedValues(b)
        try check("re-reading or re-exporting a merged total never counts it again") {
            let before = a.usage
            try a.capture(DeviceShareSnapshot(values: observedA, usage: [usage(3)]), observed: &observedA)
            try a.merge(b); try a.merge(b)
            try require(a.usage == before && a.usage[usage(0).id]?.total == 3, "double counted remote total")
        }
        try check("reservation is an exact device component increment") {
            try a.capture(DeviceShareSnapshot(values: observedA, usage: [usage(4)]), observed: &observedA, reservations: [usage(0).id])
            try require(a.usage[usage(0).id]?.components[deviceA] == 2 && a.usage[usage(0).id]?.total == 4, "wrong reservation")
            try b.merge(a); try require(b.usage[usage(0).id]?.total == 4, "reservation not propagated")
        }
        try check("absolute external usage corrections merge as floors") {
            try a.capture(DeviceShareSnapshot(values: observedA, usage: [usage(8)]), observed: &observedA)
            try b.capture(DeviceShareSnapshot(values: observedB, usage: [usage(8)]), observed: &observedB)
            try a.merge(b); try b.merge(a)
            try require(a.usage[usage(0).id]?.total == 8 && b.usage[usage(0).id]?.total == 8, "external total counted twice")
        }
        try check("requests after a correction add above the calibrated total") {
            try a.capture(DeviceShareSnapshot(values: observedA, usage: [usage(9)]), observed: &observedA, reservations: [usage(0).id])
            try b.capture(DeviceShareSnapshot(values: observedB, usage: [usage(9)]), observed: &observedB, reservations: [usage(0).id])
            try a.merge(b); try b.merge(a)
            try require(a.usage[usage(0).id]?.total == 10 && b.usage[usage(0).id]?.total == 10, "calls lost after floor")
        }
        try check("deletions cannot be undone by an offline stale replica") {
            var edited = a, observed = observedValues(a)
            let stale = b
            var values = observed; values.removeValue(forKey: "customer/a")
            try edited.capture(DeviceShareSnapshot(values: values), observed: &observed)
            try edited.merge(stale)
            try require(edited.records["customer/a"]?.value == nil && edited.records["customer/b"]?.value == second, "deletion resurrected")
        }
        try check("concurrent edits of one entry converge to one deterministic revision") {
            var aa = a, bb = b, oa = observedValues(a), ob = observedValues(b)
            var va = oa, vb = ob; va["customer/a"] = first; vb["customer/a"] = second
            try aa.capture(DeviceShareSnapshot(values: va), observed: &oa)
            try bb.capture(DeviceShareSnapshot(values: vb), observed: &ob)
            var left = aa, right = bb; try left.merge(bb); try right.merge(aa)
            try require(left.records == right.records, "same entry diverged")
        }
        try check("building identity ignores floor and normalizes city alias") {
            let x = DeviceShareCodec.addressIdentity("대전 중구 유천로 35 2층")
            let y = DeviceShareCodec.addressIdentity("대전광역시 중구 유천로 35 (유천동)")
            try require(x == y && x != DeviceShareCodec.addressIdentity("대전광역시 중구 유천로 35-1"), "building key changed")
        }
        try check("new periods do not carry yesterday's block or usage") {
            var copy = a, observed = observedValues(a)
            try copy.capture(DeviceShareSnapshot(values: observed, usage: [usage(10, blocked: true), usage(0, period: "2026-10-12")]), observed: &observed)
            try require(copy.usage[usage(0).id]?.observation.blocked == true && copy.usage[usage(0, period: "2026-10-12").id]?.total == 0 && copy.usage[usage(0, period: "2026-10-12").id]?.observation.blocked == false, "periods mixed")
        }
        try check("different keys and daily/monthly buckets remain independent") {
            var copy = a, observed = observedValues(a)
            let items = [usage(2, account: "another-key"), usage(5, period: "2026-10", domain: "naver", slot: "maps"), usage(6, period: "2026-10", domain: "naver", slot: "searchMonth")]
            try copy.capture(DeviceShareSnapshot(values: observed, usage: items), observed: &observed)
            try require(items.allSatisfy { copy.usage[$0.id]?.total == $0.used }, "keys or periods mixed")
        }
        try check("all credential bundles survive an exact encoded roundtrip") {
            var replica = DeviceShareReplica(deviceID: deviceA), observed: [String: Data] = [:]
            let values = [
                "setting/tmap": try DeviceShareCodec.encode(DeviceShareTMapSettings(appKey: "fixture-tmap", freeConfirmed: true)),
                "setting/naver-search": try DeviceShareCodec.encode(DeviceShareNaverSearch(id: "fixture-id", secret: "fixture-secret", provider: "hub", freeConfirmed: true)),
                "setting/naver-maps": try DeviceShareCodec.encode(DeviceShareNaverMaps(id: "fixture-maps", secret: "fixture-secret", freeConfirmed: true)),
                "setting/public-data": try DeviceShareCodec.encode(DeviceSharePublicSettings(key: "fixture-public", approved: ["stores"], limits: ["stores": 12]))]
            try replica.capture(DeviceShareSnapshot(values: values), observed: &observed)
            let restored = try DeviceShareReplica.decoded(replica.encoded())
            try require(replica == restored && observedValues(restored) == values, "credential roundtrip")
        }
        try check("checksum corruption and unknown schema are rejected") {
            var object = try JSONSerialization.jsonObject(with: a.encoded()) as! [String: Any]
            object["sha256"] = String(repeating: "0", count: 64)
            try fails { _ = try DeviceShareReplica.decoded(JSONSerialization.data(withJSONObject: object)) }
            object["version"] = 2
            try fails { _ = try DeviceShareReplica.decoded(JSONSerialization.data(withJSONObject: object)) }
        }
        try check("same stamp with different content is rejected rather than silently chosen") {
            var altered = a
            let key = altered.records.keys.first!
            altered.records[key]!.value = second + first
            try fails { var copy = a; try copy.merge(altered) }
        }
        try check("oversized or negative counters are rejected without integer overflow") {
            var bad = a
            bad.usage[usage(0).id]!.components[deviceA] = Int.max
            try fails { try bad.validate() }
            bad.usage[usage(0).id]!.components[deviceA] = -1
            try fails { try bad.validate() }
        }
        try check("protected checkpoint preserves replica identity, tombstones and observed values") {
            let checkpoint = DeviceShareCheckpoint(replica: a, observed: observedA)
            let restored = try DeviceShareCodec.decode(DeviceShareCheckpoint.self, DeviceShareCodec.encode(checkpoint))
            try require(restored.replica == a && restored.observed == observedA, "checkpoint restoration")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try check("coordinated folder IO writes one file per device and reads both") {
            try DeviceShareFolderIO.write(a, to: folder); try DeviceShareFolderIO.write(b, to: folder)
            let replicas = try DeviceShareFolderIO.read(folder)
            try require(replicas.count == 2 && Set(replicas.map(\.deviceID)) == [deviceA, deviceB], "one device overwrote another")
        }
        try check("updating one device file keeps the other file unchanged") {
            let other = folder.appendingPathComponent(DeviceShareFolderIO.folderName).appendingPathComponent("device-" + deviceB + ".json")
            let before = try Data(contentsOf: other)
            try DeviceShareFolderIO.write(a, to: folder)
            try require(try Data(contentsOf: other) == before, "overwrote other file")
        }
        try check("corrupt shared file stops a merge and is preserved") {
            let bad = folder.appendingPathComponent(DeviceShareFolderIO.folderName).appendingPathComponent("device-broken.json")
            let bytes = Data("broken fixture".utf8); try bytes.write(to: bad)
            try fails { _ = try DeviceShareFolderIO.read(folder) }
            try require(try Data(contentsOf: bad) == bytes, "bad bytes overwritten")
        }
        // Exercise many independently ordered updates, not just one happy-path pair.
        try check("randomized offline component merges are associative and idempotent") {
            for iteration in 1...100 {
                var aa = DeviceShareReplica(deviceID: deviceA), bb = DeviceShareReplica(deviceID: deviceB)
                var oa: [String: Data] = [:], ob: [String: Data] = [:]
                try aa.capture(DeviceShareSnapshot(usage: [usage(iteration)]), observed: &oa)
                try bb.capture(DeviceShareSnapshot(usage: [usage(101 - iteration)]), observed: &ob)
                var left = aa, right = bb
                try left.merge(bb); try left.merge(aa); try right.merge(aa); try right.merge(bb)
                try require(left.usage == right.usage && left.usage[usage(0).id]?.total == 101, "component merge instability")
            }
        }
        print("Device sharing native checks: \(passed)/\(passed) passed")
    }
}
