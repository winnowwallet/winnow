@preconcurrency import BackgroundTasks
import Foundation
import UIKit

/// iOS chooses the actual start time. Earliest-begin dates are requests, never
/// a channel-safety promise. Both task types enter the same serialized scan.
@MainActor
final class BackgroundSyncScheduler {
    static let shared = BackgroundSyncScheduler()
    static let refreshID = "com.btcswift.winnow.chain-refresh"
    static let processingID = "com.btcswift.winnow.chain-processing"
    private weak var model: AppModel?
    private var registered = false

    func register(model: AppModel) {
        self.model = model
        guard !registered else { return }
        registered = true
        for identifier in [Self.refreshID, Self.processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated { self?.handle(task) }
            }
        }
    }
    func schedule() {
        guard registered else { return }
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        refresh.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        let processing = BGProcessingTaskRequest(identifier: Self.processingID)
        processing.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        // Replacing our own requests keeps one of each pending. A request can
        // be refused (for example Background App Refresh disabled); the UI
        // reports the OS setting and never claims a scheduled check succeeded.
        for request in [refresh as BGTaskRequest, processing] {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.identifier)
            try? BGTaskScheduler.shared.submit(request)
        }
    }
    private func handle(_ task: BGTask) {
        schedule()
        guard let model else { task.setTaskCompleted(success: false); return }
        let run = BackgroundSyncRun(model: model, budget: task is BGProcessingTask ? .seconds(120) : .seconds(25)) {
            task.expirationHandler = nil
            task.setTaskCompleted(success: $0)
        }
        task.expirationHandler = { Task { @MainActor in run.expire() } }
        run.start()
    }
}

/// One completion, including expiry during startup or foreground handoff.
/// Kept independent of BGTask so lifecycle behavior can be tested in-app.
@MainActor
final class BackgroundSyncRun {
    private let work: @MainActor () async -> Bool
    private let cancel: @MainActor () async -> Void
    private let budget: Duration
    private let completion: @MainActor (Bool) -> Void
    private var running: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var expired = false
    private var finished = false

    convenience init(model: AppModel, budget: Duration, completion: @escaping @MainActor (Bool) -> Void) {
        self.init(budget: budget, work: { await model.runBackgroundSync() },
                  cancel: { await model.cancelBackgroundSync() }, completion: completion)
    }
    init(budget: Duration, work: @escaping @MainActor () async -> Bool,
         cancel: @escaping @MainActor () async -> Void, completion: @escaping @MainActor (Bool) -> Void) {
        self.budget = budget; self.work = work; self.cancel = cancel; self.completion = completion
    }
    func start() {
        guard running == nil, !finished else { return }
        running = Task {
            if expired { finish(false); return }
            let success = await work()
            finish(success && !expired)
        }
        deadline = Task {
            do { try await Task.sleep(for: budget); expire() }
            catch { }
        }
    }
    func expire() {
        guard !finished, !expired else { return }
        expired = true
        running?.cancel()
        Task { await cancel() }
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil; running = nil
        completion(success)
    }
}
