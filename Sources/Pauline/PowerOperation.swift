import Foundation

/// Only one power transition may run at a time, including across suspension points.
/// Shutdown closes admission before waiting for the last transition to finish.
@MainActor
final class PowerOperation {
    private var task: Task<Void, Never>?
    private(set) var isStopping = false
    var isBusy: Bool { task != nil }

    @discardableResult
    func run(_ body: @escaping @MainActor () async -> Void) -> Bool {
        guard task == nil, !isStopping else { return false }
        task = Task {
            await body()
            task = nil
        }
        return true
    }

    func wait() async { await task?.value }

    func runWhenIdle(_ body: @escaping @MainActor () async -> Void) async {
        while task != nil, !isStopping { await wait() }
        run(body)
    }

    func stop() async {
        isStopping = true
        await wait()
    }
}
