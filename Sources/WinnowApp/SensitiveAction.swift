import Foundation
import LocalAuthentication
import Observation

/// One sensitive sheet action at a time: showing the recovery phrase,
/// importing a bundle, exporting a backup. Its result or error reaches the
/// view only while the presentation that started it is still current and the
/// scene may present (`SensitivePresentationEpoch`). Leaving the sheet,
/// cancellation and declining the device-owner prompt end it quietly.
@MainActor
@Observable
final class SensitiveAction {
    private(set) var busy = false
    private(set) var error: String?
    @ObservationIgnored private var epoch = SensitivePresentationEpoch()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Replaces any earlier run. `presentable` is asked at each boundary, so a
    /// scene that went to the background in the meantime discards the result.
    func start<Value>(presentable: @escaping @MainActor () -> Bool,
                      _ operation: @escaping @MainActor () async throws -> Value,
                      apply: @escaping @MainActor (Value) throws -> Void) {
        task?.cancel()
        let token = epoch.begin()
        busy = true
        error = nil
        task = Task { @MainActor in
            await self.run(token, presentable: presentable, operation, apply: apply)
        }
    }

    /// Ends any run and forgets its state; a late result is discarded.
    func reset() {
        epoch.invalidate()
        task?.cancel()
        task = nil
        busy = false
        error = nil
    }

    /// Waits for the current run, for callers that sequence on it.
    func finish() async {
        await task?.value
    }

    private func run<Value>(_ token: SensitivePresentationEpoch.Token,
                            presentable: @MainActor () -> Bool,
                            _ operation: @MainActor () async throws -> Value,
                            apply: @MainActor (Value) throws -> Void) async {
        do {
            let value = try await operation()
            try Task.checkCancellation()
            guard epoch.accepts(token, whilePresentationIsAllowed: presentable()) else { return }
            try apply(value)
        } catch is CancellationError {
            // Leaving the sheet or the active scene is an intentional exit.
        } catch let error as LAError where error.code == .userCancel {
            // Declining the prompt is a decision, not a failure.
        } catch {
            if epoch.accepts(token, whilePresentationIsAllowed: presentable()) {
                self.error = error.localizedDescription
            }
        }
        guard epoch.accepts(token, whilePresentationIsAllowed: presentable()) else { return }
        busy = false
        task = nil
    }
}
