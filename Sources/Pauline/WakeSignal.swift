import Foundation

/// Event-driven, cancellable waits with a monotonic deadline. A revision prevents lost wakeups
/// when a producer signals between inspecting state and registering a waiter.
@MainActor
final class WakeSignal {
    private(set) var revision = 0
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        revision += 1
        for id in Array(waiters.keys) { finish(id, changed: true) }
    }

    func wait(after revision: Int, timeout: Duration) async -> Bool {
        guard !Task.isCancelled, timeout > .zero else { return false }
        if revision != self.revision { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    finish(id, changed: false)
                }
                waiters[id] = Waiter(continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, changed: false) }
        }
    }

    private func finish(_ id: UUID, changed: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: changed)
    }
}
