import Foundation
import Testing
@testable import Pauline

@Suite("Bounded system commands")
struct SystemTests {
    @Test func flagConfirmationChecksDeadlineAndCancellation() async {
        #expect(await SleepSetting.waitForFlag(disabled: true, read: { true }))
        #expect(!(await SleepSetting.waitForFlag(disabled: true, timeout: .milliseconds(30), read: { false })))
        let waiting = Task {
            await SleepSetting.waitForFlag(disabled: true, timeout: .seconds(30), read: { false })
        }
        waiting.cancel()
        #expect(!(await waiting.value))
    }

    @Test func preservesExitCodesAndSpawnFailures() async {
        #expect(await Shell.runAsync("/usr/bin/true", []) == 0)
        #expect(await Shell.runAsync("/usr/bin/false", []) == 1)
        #expect(await Shell.runAsync("/does-not-exist/pauline", []) == -1)
    }

    @Test func terminatesAnUnresponsiveChild() async {
        let started = ContinuousClock.now
        // Ignores TERM, exercising the bounded KILL fallback without touching power settings.
        let result = await Shell.runAsync("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: .milliseconds(100))
        #expect(result == -1)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test @MainActor func mainActorRemainsResponsive() async {
        var completed = false
        let command = Task { @MainActor in
            _ = await Shell.runAsync("/bin/sleep", ["10"], timeout: .milliseconds(500))
            completed = true
        }
        // The command has started, but a MainActor continuation can still run before it completes.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!completed)
        await command.value
        #expect(completed)
    }

    @Test @MainActor func shutdownWaitsForEnableAndRejectsNewOperations() async {
        let operation = PowerOperation()
        let latch = Latch()
        var events: [String] = []
        #expect(operation.run {
            events.append("enable started")
            await latch.wait()
            events.append("enable finished")
        })
        #expect(!operation.run { events.append("overlap") })
        let shutdown = Task { @MainActor in
            await operation.stop()
            events.append("restore")
        }
        while !operation.isStopping { await Task.yield() }
        #expect(!operation.run { events.append("late enable") })
        latch.release()
        await shutdown.value
        #expect(events == ["enable started", "enable finished", "restore"])
        #expect(!operation.isBusy)
    }
}

@MainActor
private final class Latch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
