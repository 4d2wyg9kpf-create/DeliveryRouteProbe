import Foundation
import Combine
#if canImport(UIKit) && canImport(BackgroundTasks)
import UIKit
import BackgroundTasks
#endif

@MainActor
final class HousingCollectionStatus: ObservableObject {
    @Published var value: HousingCollectionProgress?
    @Published var backgroundMessage = ""
    @Published var resumeAt: Date?
}

// Only explicit collection/resume buttons submit a Continued Processing task.
// Expiration cancels network work; the SQLite journal already holds each success.
@MainActor
final class HousingCollectionBackground {
    static let shared = HousingCollectionBackground()
    private var runID: UUID?
    private var startWork: (() -> Void)?
    private var expireWork: (() -> Void)?
    private var identifier: String?
    private var isBackground = false
    #if canImport(UIKit) && canImport(BackgroundTasks)
    private var continued: AnyObject?
    private var shortTask = UIBackgroundTaskIdentifier.invalid
    #endif
    func begin(id: UUID, title: String, status: HousingCollectionStatus,
               start: @escaping () -> Void, expire: @escaping () -> Void) {
        runID = id; startWork = start; expireWork = expire
        #if canImport(UIKit) && canImport(BackgroundTasks)
        if #available(iOS 26.0, *) {
            let name = "kr.deliverytools.routeprobe.housing." + id.uuidString
            identifier = name
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: name, using: .main) { [weak self, weak status] task in
                Task { @MainActor in
                    guard let self, self.runID == id, let continued = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false); return
                    }
                    self.continued = continued
                    continued.progress.totalUnitCount = -1
                    continued.expirationHandler = { [weak self] in Task { @MainActor in self?.expired(id: id) } }
                    status?.backgroundMessage = "화면을 닫거나 다른 앱을 사용해도 수집을 계속합니다."
                    let work = self.startWork; self.startWork = nil; work?()
                }
            }
            if registered {
                let request = BGContinuedProcessingTaskRequest(identifier: name, title: "공동주택 수집", subtitle: title + " · 전체 단지 확인 중")
                request.strategy = .fail
                do {
                    try BGTaskScheduler.shared.submit(request)
                    status.backgroundMessage = "백그라운드 수집 시작 중"
                    return
                } catch { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: name) }
            }
        }
        status.backgroundMessage = "장시간 백그라운드 실행을 사용할 수 없습니다. 화면을 닫으면 허용된 시간만 수집하고 작업을 보관합니다."
        #else
        status.backgroundMessage = "수집 작업을 실행 중입니다."
        #endif
        let work = startWork; startWork = nil; work?()
        sceneChanged(background: isBackground)
    }
    func update(id: UUID, progress: HousingCollectionProgress) {
        guard runID == id else { return }
        #if canImport(UIKit) && canImport(BackgroundTasks)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            if let total = progress.totalComplexCount {
                task.progress.totalUnitCount = Int64(max(1, total))
                task.progress.completedUnitCount = Int64(total == 0 ? 1 : progress.completedComplexCount)
            } else {
                task.progress.totalUnitCount = -1
                task.progress.completedUnitCount = Int64(progress.discoveredRegions + progress.inventory.count)
            }
            task.updateTitle("공동주택 수집", subtitle: String(progress.summary.prefix(160)))
        }
        #endif
    }
    func sceneChanged(background: Bool) {
        isBackground = background
        #if canImport(UIKit) && canImport(BackgroundTasks)
        if !background { endShortTask(); return }
        guard let id = runID, continued == nil, shortTask == .invalid else { return }
        shortTask = UIApplication.shared.beginBackgroundTask(withName: "공동주택 수집 저장") { [weak self] in
            Task { @MainActor in self?.expired(id: id) }
        }
        if shortTask == .invalid { expired(id: id) }
        #endif
    }
    func expired(id: UUID) {
        guard runID == id else { return }
        expireWork?()
        finish(id: id, success: false)
    }
    func finish(id: UUID, success: Bool) {
        guard runID == id else { return }
        #if canImport(UIKit) && canImport(BackgroundTasks)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.expirationHandler = nil; task.setTaskCompleted(success: success)
        }
        continued = nil; endShortTask()
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        #endif
        runID = nil; identifier = nil; startWork = nil; expireWork = nil
    }
    #if canImport(UIKit) && canImport(BackgroundTasks)
    private func endShortTask() {
        guard shortTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(shortTask); shortTask = .invalid
    }
    #endif
}
