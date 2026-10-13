import Foundation
import Combine

enum DeviceShareFolderIO {
    static let folderName = "DeliveryRouteShare"
    static func read(_ folder: URL) throws -> [DeviceShareReplica] {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var files: [URL] = []
        var listingError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) { selected in
            do {
                let directory = selected.appendingPathComponent(folderName, isDirectory: true)
                guard FileManager.default.fileExists(atPath: directory.path) else { return }
                files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
                    .filter { $0.lastPathComponent.hasPrefix("device-") && $0.pathExtension == "json" }
                guard files.count <= 100 else { throw DeviceShareError.invalid }
            } catch { listingError = error }
        }
        if coordinationError != nil { throw DeviceShareError.unavailable }
        if let listingError { throw listingError }
        var result: [DeviceShareReplica] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var error: NSError?; var readResult: Result<DeviceShareReplica, Error>?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { url in
                readResult = Result {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 250_000_000 else { throw DeviceShareError.invalid }
                    return try DeviceShareReplica.decoded(Data(contentsOf: url))
                }
            }
            if error != nil { throw DeviceShareError.unavailable }
            guard let readResult else { throw DeviceShareError.unavailable }
            result.append(try readResult.get())
        }
        return result
    }
    static func write(_ replica: DeviceShareReplica, to folder: URL) throws {
        let data = try replica.encoded()
        guard data.count <= 250_000_000 else { throw DeviceShareError.invalid }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?; var writingError: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { selected in
            do {
                let directory = selected.appendingPathComponent(folderName, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("device-" + replica.deviceID + ".json")
                try data.write(to: file, options: .atomic)
            } catch { writingError = error }
        }
        if coordinationError != nil { throw DeviceShareError.unavailable }
        if let writingError { throw writingError }
    }
}

@MainActor
final class DeviceSharingStore: ObservableObject {
    static let shared = DeviceSharingStore()
    @Published private(set) var enabled = false
    @Published private(set) var folderName = ""
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var deviceCount = 0
    @Published private(set) var message = "각 기기에서 iCloud Drive의 같은 폴더를 선택하세요."
    @Published private(set) var errorMessage: String?
    private var checkpoint = DeviceShareCheckpoint(replica: DeviceShareReplica(deviceID: UUID().uuidString))
    private var checkpointURL: URL
    private var folder: URL?
    private var localError = false
    private var applying = false
    private var connecting = false
    private var snapshot: (() throws -> DeviceShareSnapshot)?
    private var apply: ((DeviceShareReplica) throws -> Void)?
    private var catalogSync: ((URL) async throws -> Void)?
    private var syncTask: Task<Void, Error>?
    private var saveTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var active = true
    private let defaults: UserDefaults
    private static let bookmarkKey = "delivery.shared-folder.bookmark.v1"
    private static let enabledKey = "delivery.shared-folder.enabled.v1"
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeliveryRouteDeviceShare", isDirectory: true)
        checkpointURL = root.appendingPathComponent("replica.state")
        do {
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                checkpoint = try DeviceShareCodec.decode(DeviceShareCheckpoint.self, Data(contentsOf: checkpointURL))
                guard checkpoint.version == 1 else { throw DeviceShareError.newerVersion }
                try checkpoint.replica.validate()
            }
        } catch { localError = true; errorMessage = DeviceShareError.invalid.localizedDescription }
        enabled = defaults.bool(forKey: Self.enabledKey)
        if enabled { restoreFolder() }
    }
    private func restoreFolder() {
        do {
            guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { throw DeviceShareError.unavailable }
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                defaults.set(try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: Self.bookmarkKey)
            }
            folder = url; folderName = url.lastPathComponent
        } catch { errorMessage = DeviceShareError.unavailable.localizedDescription }
    }
    func bind(snapshot: @escaping () throws -> DeviceShareSnapshot, apply: @escaping (DeviceShareReplica) throws -> Void, catalogSync: ((URL) async throws -> Void)? = nil) {
        self.snapshot = snapshot; self.apply = apply; self.catalogSync = catalogSync
        DeviceShareHooks.didChange = { [weak self] reservations in try self?.capture(reservations: reservations) }
        DeviceShareHooks.beforeRequest = { [weak self] in
            guard let self else { return }
            guard !self.connecting else { throw DeviceShareError.unavailable }
            guard self.enabled else { return }
            try await self.synchronize()
        }
        setActive(true)
        if enabled { schedule() }
    }
    func connect(_ url: URL) async throws {
        guard !isSyncing, !connecting, !localError else { throw DeviceShareError.invalid }
        connecting = true; isSyncing = true
        defer { connecting = false; isSyncing = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        // Verify readable folder access before changing the saved connection.
        _ = try await Task.detached(priority: .utility) { try DeviceShareFolderIO.read(url) }.value
        folder = url; folderName = url.lastPathComponent; enabled = true
        defaults.set(bookmark, forKey: Self.bookmarkKey); defaults.set(true, forKey: Self.enabledKey)
        errorMessage = nil; setActive(active)
        try capture()
        try await synchronize()
    }
    func disconnect() {
        guard !isSyncing else { return }
        enabled = false; folder = nil; folderName = ""; errorMessage = nil; deviceCount = 0
        defaults.removeObject(forKey: Self.bookmarkKey); defaults.set(false, forKey: Self.enabledKey)
        saveTask?.cancel(); pollingTask?.cancel()
        message = "공유 연결을 해제했습니다. 현재 기기의 키와 목록은 유지됩니다."
    }
    func setActive(_ active: Bool) {
        self.active = active
        pollingTask?.cancel(); pollingTask = nil
        guard enabled, active else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, self.enabled, self.active else { return }
                do { try await self.synchronize() } catch { }
            }
        }
        schedule()
    }
    private func persist() throws {
        guard !localError else { throw DeviceShareError.invalid }
        let data = try DeviceShareCodec.encode(checkpoint)
        guard data.count <= 250_000_000 else { throw DeviceShareError.invalid }
        let directory = checkpointURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        #if os(iOS)
        try data.write(to: checkpointURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: checkpointURL, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
    }
    private func capture(reservations: [String] = []) throws {
        guard enabled, !applying else { return }
        guard !localError, let snapshot else { throw DeviceShareError.invalid }
        var next = checkpoint
        try next.replica.capture(snapshot(), observed: &next.observed, reservations: reservations)
        let previous = checkpoint; checkpoint = next
        do { try persist() }
        catch { checkpoint = previous; errorMessage = DeviceShareError.unavailable.localizedDescription; throw DeviceShareError.unavailable }
        schedule()
    }
    private func schedule() {
        guard enabled, active else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self else { return }
            do { try await self.synchronize() } catch { }
        }
    }
    func synchronize() async throws {
        guard enabled else { return }
        if let syncTask { try await syncTask.value; return }
        guard !localError, folder != nil, snapshot != nil, apply != nil else {
            errorMessage = DeviceShareError.unavailable.localizedDescription
            throw DeviceShareError.unavailable
        }
        let task = Task { [weak self] in guard let self else { return }; try await self.performSync() }
        syncTask = task
        defer { syncTask = nil }
        try await task.value
    }
    private func performSync() async throws {
        guard let folder, let snapshot, let apply else { throw DeviceShareError.unavailable }
        isSyncing = true; defer { isSyncing = false }
        do {
            // Capture before and after asynchronous IO; edits made during a read must survive.
            try captureWithoutScheduling(snapshot())
            let replicas = try await Task.detached(priority: .utility) { try DeviceShareFolderIO.read(folder) }.value
            try Task.checkCancellation()
            try captureWithoutScheduling(snapshot())
            var merged = checkpoint.replica
            for replica in replicas { try merged.merge(replica) }
            checkpoint.replica = merged; try persist()
            applying = true
            do {
                try apply(merged)
                checkpoint.observed = try snapshot().values
                try persist(); applying = false
            } catch {
                // Avoid re-exporting a partially applied remote edit as a new local edit.
                if let current = try? snapshot() { checkpoint.observed = current.values; try? persist() }
                applying = false; throw error
            }
            let outgoing = checkpoint.replica
            try await Task.detached(priority: .utility) { try DeviceShareFolderIO.write(outgoing, to: folder) }.value
            try await catalogSync?(folder)
            lastSync = Date(); deviceCount = Set(replicas.map(\.deviceID) + [outgoing.deviceID]).count
            errorMessage = nil; message = "키·목록·사용량을 동기화했습니다."
        } catch {
            errorMessage = (error as? DeviceShareError)?.localizedDescription ?? DeviceShareError.unavailable.localizedDescription
            throw DeviceShareError.unavailable
        }
    }
    private func captureWithoutScheduling(_ snapshot: DeviceShareSnapshot) throws {
        var next = checkpoint
        try next.replica.capture(snapshot, observed: &next.observed)
        checkpoint = next; try persist()
    }
}
