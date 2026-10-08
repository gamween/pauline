import Foundation
import Testing
import PaulineCore
@testable import Pauline

@Suite("Telegram reliability", .serialized)
@MainActor
struct TelegramReliabilityTests {
    private func config() -> TelegramConfig {
        TelegramConfig(token: "local-test", botUsername: "local_test", chatID: 1)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalTelegramProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func connectionReportsStorageFailureWithoutStartingPolling() async {
        let network = LocalTelegramProtocol.reset()
        let transport = session()
        defer { transport.invalidateAndCancel() }
        let bot = TelegramBot(config: nil, transport: transport, save: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }, delete: {})
        do {
            try await bot.connect(token: "1:" + String(repeating: "a", count: 30))
            Issue.record("Connection must fail when credentials cannot be saved")
        } catch {
            #expect(error.localizedDescription.contains("saved"))
        }
        #expect(!bot.isLinked)
        #expect(!bot.isWaitingForStart)
        #expect(network.requests.map(\.lastPathComponent) == ["getMe", "getWebhookInfo"])
    }

    @Test func openingWaitsForDurableStorageAndRecovers() async {
        let network = LocalTelegramProtocol.reset()
        let transport = session()
        defer { transport.invalidateAndCancel() }
        var writable = false
        var persisted: TelegramConfig?
        let attempts = WakeSignal()
        let bot = TelegramBot(config: config(), transport: transport, save: { value in
            attempts.signal()
            guard writable else { throw CocoaError(.fileWriteOutOfSpace) }
            persisted = value
        }, delete: {})
        let revision = attempts.revision
        bot.sync(PowerState(sleepDisabled: true))
        #expect(await attempts.wait(after: revision, timeout: .seconds(2)))
        #expect(network.requests.isEmpty)
        #expect(bot.problem?.contains("saved") == true)
        writable = true
        await bot.drain(timeout: 2)
        #expect(persisted?.session != nil)
        #expect(network.requests.count == 1)
        #expect(bot.problem == nil)
        #expect(!bot.hasPendingMessages)
        bot.close(.mac, state: PowerState(sleepDisabled: false))
        await bot.drain(timeout: 2)
        #expect(persisted?.session == nil)
        _ = await bot.disconnect()
    }

    @Test func closingWaitsForItsRecoveryRecord() async {
        let network = LocalTelegramProtocol.reset()
        let transport = session()
        defer { transport.invalidateAndCancel() }
        var writable = true
        var persisted: TelegramConfig?
        let attempts = WakeSignal()
        let bot = TelegramBot(config: config(), transport: transport, save: { value in
            attempts.signal()
            guard writable else { throw CocoaError(.fileWriteNoPermission) }
            persisted = value
        }, delete: {})
        bot.sync(PowerState(sleepDisabled: true))
        await bot.drain(timeout: 2)
        #expect(network.requests.count == 1)
        writable = false
        let revision = attempts.revision
        bot.close(.mac, state: PowerState(sleepDisabled: false))
        #expect(await attempts.wait(after: revision, timeout: .seconds(2)))
        #expect(network.requests.count == 1)
        #expect(persisted?.session?.closingText == nil)
        writable = true
        await bot.drain(timeout: 2)
        #expect(network.requests.count == 2)
        #expect(persisted?.session == nil)
        _ = await bot.disconnect()
    }

    @Test func queueIsBoundedAndPrunesBehindBlockedSessions() async {
        let network = LocalTelegramProtocol.reset()
        let transport = session()
        defer { transport.invalidateAndCancel() }
        var date = Date()
        var writable = false
        var persisted: TelegramConfig?
        let bot = TelegramBot(config: config(), transport: transport, now: { date }, save: { value in
            guard writable else { throw CocoaError(.fileWriteOutOfSpace) }
            persisted = value
        }, delete: {})
        bot.sync(PowerState(sleepDisabled: true))
        for _ in 0..<1_000 { bot.reply("status") }
        #expect(bot.pendingCount == TelegramBot.transientLimit + 1)
        // Advancing the injected clock expires responses even though the opening is still first.
        date = date.addingTimeInterval(121)
        bot.reply("fresh status")
        #expect(bot.pendingCount == 2)
        writable = true
        await bot.drain(timeout: 2)
        #expect(network.requests.count == 2)
        #expect(persisted?.session != nil)
        bot.close(.mac, state: PowerState(sleepDisabled: false))
        await bot.drain(timeout: 2)
        #expect(network.requests.count == 3)
        _ = await bot.disconnect()
    }

    @Test func drainCancellationReturnsPromptly() async {
        _ = LocalTelegramProtocol.reset()
        let transport = session()
        defer { transport.invalidateAndCancel() }
        var writable = false
        let bot = TelegramBot(config: config(), transport: transport, save: { _ in
            guard writable else { throw CocoaError(.fileWriteOutOfSpace) }
        }, delete: {})
        bot.sync(PowerState(sleepDisabled: true))
        let started = ContinuousClock.now
        let drain = Task { await bot.drain(timeout: 30) }
        drain.cancel()
        await drain.value
        #expect(started.duration(to: .now) < .seconds(1))
        writable = true
        await bot.drain(timeout: 2)
        _ = await bot.disconnect()
    }

    @Test func drainInterruptsNetworkBackoff() async {
        let network = LocalTelegramProtocol.reset()
        network.response = #"{"ok":false,"error_code":500,"description":"temporary failure"}"#
        let transport = session()
        defer { transport.invalidateAndCancel() }
        let bot = TelegramBot(config: config(), transport: transport, save: { _ in }, delete: {})
        bot.sync(PowerState(sleepDisabled: true))
        // A short drain observes the first failure but ends before the five-second retry.
        await bot.drain(timeout: 0.1)
        #expect(bot.hasPendingMessages)
        #expect(network.requests.count >= 1)
        network.response = #"{"ok":true,"result":{}}"#
        let started = ContinuousClock.now
        await bot.drain(timeout: 2)
        #expect(!bot.hasPendingMessages)
        #expect(started.duration(to: .now) < .seconds(2))
        _ = await bot.disconnect()
    }

    @Test func drainDoesNotBypassRateLimit() async {
        let network = LocalTelegramProtocol.reset()
        network.response = #"{"ok":false,"error_code":429,"description":"retry later","parameters":{"retry_after":1}}"#
        let transport = session()
        defer { transport.invalidateAndCancel() }
        let bot = TelegramBot(config: config(), transport: transport, save: { _ in }, delete: {})
        bot.sync(PowerState(sleepDisabled: true))
        await bot.drain(timeout: 0.1)
        #expect(network.requests.count == 1)
        network.response = #"{"ok":true,"result":{}}"#
        await bot.drain(timeout: 0.1)
        #expect(network.requests.count == 1)
        #expect(bot.hasPendingMessages)
        await bot.drain(timeout: 2)
        #expect(!bot.hasPendingMessages)
        _ = await bot.disconnect()
    }

    @Test func signalWakesAllWaitersAndRemembersEarlySignals() async {
        let signal = WakeSignal()
        let revision = signal.revision
        let first = Task { await signal.wait(after: revision, timeout: .seconds(30)) }
        let second = Task { await signal.wait(after: revision, timeout: .seconds(30)) }
        await Task.yield()
        signal.signal()
        #expect(await first.value)
        #expect(await second.value)
        #expect(await signal.wait(after: revision, timeout: .seconds(30)))
    }

    @Test func signalHonorsDeadlineAndCancellation() async {
        let signal = WakeSignal()
        #expect(!(await signal.wait(after: signal.revision, timeout: .milliseconds(10))))
        let waiter = Task { await signal.wait(after: signal.revision, timeout: .seconds(30)) }
        waiter.cancel()
        #expect(!(await waiter.value))
    }
}

/// Every request is intercepted; tests cannot reach Telegram or require a bot token.
private final class LocalTelegramProtocol: URLProtocol, @unchecked Sendable {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URL] = []
        private var responseBody = #"{"ok":true,"result":{}}"#
        var requests: [URL] { lock.withLock { recorded } }
        var response: String {
            get { lock.withLock { responseBody } }
            set { lock.withLock { responseBody = newValue } }
        }
        func record(_ url: URL) { lock.withLock { recorded.append(url) } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorder = Recorder()
    static func reset() -> Recorder {
        lock.withLock {
            recorder = Recorder()
            return recorder
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let recorder = Self.lock.withLock { Self.recorder }
        recorder.record(url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        switch url.lastPathComponent {
        case "getMe": body = #"{"ok":true,"result":{"username":"local_test"}}"#
        case "getWebhookInfo": body = #"{"ok":true,"result":{"url":""}}"#
        default: body = recorder.response
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
