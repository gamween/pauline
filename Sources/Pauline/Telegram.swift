import Foundation
import PaulineCore

/// The bot token, the linked chat and the open session, kept in
/// ~/Library/Application Support/Pauline/telegram.json. The folder is private to the user (0700)
/// and the file too (0600). Not the Keychain on purpose: every local rebuild changes the ad hoc
/// signature, and macOS would ask for the password again.
struct TelegramConfig: Codable {
    var token: String
    var botUsername: String
    /// Set once the user taps Start in the chat with the bot.
    var chatID: Int64?
    /// Secret carried by the Start link, so only that tap can link a chat.
    var linkCode: String?
    /// The session whose opening message was sent (or tried) and whose closing message has not gone out yet.
    var session: Session?

    struct Session: Codable {
        var start: Date
        /// The closing message, written the moment the session ends, so a crash or a restart
        /// before it goes out still closes the session with the right words.
        var closingText: String?
        /// Why it will end, when Pauline quit while it could not end it (pmset refused).
        var endReason: CloseReason?
    }

    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pauline", isDirectory: true)
    }

    private static var file: URL { folder.appendingPathComponent("telegram.json") }

    static func load() -> TelegramConfig? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(TelegramConfig.self, from: data)
        } catch {
            NSLog("Pauline could not read the Telegram settings: \(error.localizedDescription)")
            return nil
        }
    }

    func save() {
        let manager = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.folder.path)
            try encoder.encode(self).write(to: Self.file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        } catch {
            NSLog("Pauline could not save the Telegram settings: \(error.localizedDescription)")
        }
    }

    static func delete() {
        do {
            try FileManager.default.removeItem(at: file)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            NSLog("Pauline could not delete the Telegram settings: \(error.localizedDescription)")
        }
    }
}

/// A thin client for the few Bot API methods Pauline uses.
struct TelegramAPI: Sendable {
    let token: String

    /// Ephemeral: no cache or cookie store on disk, so the bot token in each URL never lands there.
    private static let session = URLSession(configuration: .ephemeral)

    /// A Bot API error, with Telegram's error code when there is one.
    struct Failure: LocalizedError {
        let code: Int?
        let errorDescription: String?
        var retryAfter: Int?
    }

    private struct Envelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
        let errorCode: Int?
        let description: String?
        let parameters: Parameters?

        struct Parameters: Decodable {
            let retryAfter: Int?
        }
    }

    func call<Body: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, _ body: Body, timeout: TimeInterval = 15
    ) async throws -> Result {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw Failure(code: nil, errorDescription: "This does not look like a bot token.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await Self.session.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope<Result>.self, from: data) else {
            // Not a Bot API answer (a proxy, an outage page): no Telegram error code, so it is retried like a network error.
            let status = (response as? HTTPURLResponse)?.statusCode.description ?? "?"
            throw Failure(code: nil, errorDescription: "Telegram sent an unexpected answer (HTTP \(status)).")
        }
        guard envelope.ok, let result = envelope.result else {
            throw Failure(
                code: envelope.errorCode, errorDescription: envelope.description ?? "Telegram refused the request.",
                retryAfter: envelope.parameters?.retryAfter
            )
        }
        return result
    }

    // MARK: Bot API types, only the fields Pauline reads

    struct NoBody: Encodable, Sendable {}

    struct Bot: Decodable, Sendable {
        let username: String?
    }

    struct WebhookInfo: Decodable, Sendable {
        let url: String
    }

    struct GetUpdates: Encodable, Sendable {
        let offset: Int?
        let timeout: Int
        let allowedUpdates: [String]
    }

    struct Update: Decodable, Sendable {
        let updateId: Int
        let message: Message?
        let callbackQuery: CallbackQuery?
    }

    struct Message: Decodable, Sendable {
        let date: Int
        let chat: Chat
        let text: String?
    }

    struct Chat: Decodable, Sendable {
        let id: Int64
        let type: String
    }

    struct CallbackQuery: Decodable, Sendable {
        let id: String
        let message: Message?
        let data: String?
    }

    struct SendMessage: Encodable, Sendable {
        let chatId: Int64
        let text: String
        let replyMarkup: Keyboard?
    }

    struct Keyboard: Encodable, Sendable {
        let inlineKeyboard: [[Button]]
    }

    struct Button: Encodable, Sendable {
        let text: String
        let callbackData: String
    }

    struct AnswerCallback: Encodable, Sendable {
        let callbackQueryId: String
        let text: String?
    }

    struct SetCommands: Encodable, Sendable {
        let commands: [BotCommand]
    }

    struct BotCommand: Encodable, Sendable {
        let command: String
        let description: String
    }

    struct Ignored: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }
}

/// Talks to the user's own bot. No server involved: Pauline asks Telegram for new messages with long polling.
///
/// Every session, from Pauline on to Pauline off, gets an opening message and, whatever ends it,
/// a closing message that stays the last one of the session. Messages leave one at a time, in order,
/// from an outbox. A session is written to disk before its opening is sent and erased once its closing
/// went out, so a crash, a power loss or a network outage still ends with a closing message, on the
/// next launch at the latest.
@MainActor
final class TelegramBot {
    enum Command {
        case status
        case off
    }

    /// Called for each command from the linked chat.
    var onCommand: ((Command) -> Void)?

    private var config = TelegramConfig.load()
    /// Lasting problems for the menu. Sending and polling keep their own, so one success cannot hide the other.
    private var sendProblem: String?
    private var pollProblem: String?
    var problem: String? { sendProblem ?? pollProblem }

    private var outbox: [Outgoing] = []
    private var worker: Task<Void, Never>?
    /// The message whose request is in flight: it may already be delivered, so it is never pulled out.
    private var sending: UUID?
    /// Set when a session message is queued or a drain starts, to cut a retry wait short.
    private var retryNow = false
    /// Bumped by stop(), so a worker cancelled by a reconnect cannot touch the new outbox.
    private var generation = 0
    /// Disconnecting: the last message is on its way, nothing new may be queued behind it.
    private var leaving = false
    /// Drains waiting right now (quit, held sleep, disconnect): retries come every second, not after a long backoff.
    private var drains = 0
    /// Why the session will end, when Pauline quit while it could not end it, for an opening not yet on disk.
    private var quitEndReason: CloseReason?
    private var pollTask: Task<Void, Never>?
    private var offset: Int?

    private struct Outgoing {
        enum Kind {
            /// Opens the session that started at this date.
            case opening(Date)
            /// A reminder, the charging message or a warning, dropped once the session closes or after 2 minutes.
            case notice
            /// An answer to a command, dropped after 2 minutes.
            case reply
            /// Closes the session that started at this date. Never dropped, it waits for the network.
            case closing(Date)
            /// The last message of a session still running when Telegram gets disconnected.
            case farewell(Date)
        }

        let id = UUID()
        let kind: Kind
        let created = Date()
        let text: String
        /// Adds a Turn Pauline off button, tied to the session that started at this date.
        var offButton: Date?

        /// The session this message opens or ends.
        var session: Date? {
            switch kind {
            case .opening(let start), .closing(let start), .farewell(let start): return start
            case .notice, .reply: return nil
            }
        }

        var isNotice: Bool {
            if case .notice = kind { return true }
            return false
        }

        var isOpening: Bool {
            if case .opening = kind { return true }
            return false
        }

        /// A closing or a farewell: the last message of its session.
        var endsSession: Bool {
            switch kind {
            case .closing, .farewell: return true
            case .opening, .notice, .reply: return false
            }
        }
    }

    var isLinked: Bool { config?.chatID != nil }
    var isWaitingForStart: Bool { config != nil && config?.chatID == nil }
    var botUsername: String? { config?.botUsername }
    var hasPendingMessages: Bool { !outbox.isEmpty }

    /// The start of the session the chat sees as running: persisted without a closing text,
    /// or with its opening queued, and with no closing or farewell queued after it.
    private var activeStart: Date? {
        var active = config?.session.flatMap { $0.closingText == nil ? $0.start : nil }
        for item in outbox {
            switch item.kind {
            case .opening(let start): active = start
            case .closing, .farewell: active = nil
            case .notice, .reply: break
            }
        }
        return active
    }

    /// The links that open the bot chat with the secret code, while waiting for Start:
    /// one for Telegram for Mac, one for the web and the QR code.
    var startLinks: (app: String, web: URL)? {
        guard let config, let code = config.linkCode,
              let web = URL(string: "https://t.me/\(config.botUsername)?start=\(code)") else { return nil }
        return ("tg://resolve?domain=\(config.botUsername)&start=\(code)", web)
    }

    // MARK: Lifecycle

    /// Starts listening. A session left open by a quit while offline, a crash or a restart gets its closing now,
    /// unless Pauline could not give sleep back at launch: then it is still running and stays open.
    func start(bootedAt boot: Date?, state: PowerState) {
        guard let config else { return }
        if let session = config.session, session.closingText != nil || !state.sleepDisabled {
            let rebooted = boot.map { $0 > session.start } ?? false
            let reason = session.endReason ?? (rebooted ? .unexpectedRestart : .crash)
            let text = session.closingText ?? TelegramText.closed(reason, state: state)
            if session.closingText == nil {
                self.config?.session?.closingText = text
                self.config?.save()
            }
            enqueue(Outgoing(kind: .closing(session.start), text: text))
        } else if config.session?.endReason != nil {
            // Still running after all: the reason of an earlier quit no longer applies.
            self.config?.session?.endReason = nil
            self.config?.save()
        }
        if isLinked {
            setCommands()
        }
        pollTask = Task { await poll() }
    }

    /// Checks the token with Telegram and saves it. `startLinks` then open the chat to tap Start.
    func connect(token raw: String) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^[0-9]+:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil else {
            throw TelegramAPI.Failure(
                code: nil,
                errorDescription: "This does not look like a bot token. Copy the whole token BotFather sent, it looks like 123456789:AAH..."
            )
        }
        let api = TelegramAPI(token: token)
        let bot: TelegramAPI.Bot
        let webhook: TelegramAPI.WebhookInfo
        do {
            bot = try await api.call("getMe", TelegramAPI.NoBody())
            webhook = try await api.call("getWebhookInfo", TelegramAPI.NoBody())
        } catch let failure as TelegramAPI.Failure where failure.code == 401 || failure.code == 404 {
            throw TelegramAPI.Failure(code: failure.code, errorDescription: "Telegram does not know this token. Copy it again from BotFather.")
        } catch is URLError {
            throw TelegramAPI.Failure(code: nil, errorDescription: "Could not reach Telegram. Check the internet connection and try again.")
        }
        guard let username = bot.username else {
            throw TelegramAPI.Failure(code: nil, errorDescription: "Telegram did not return the bot name.")
        }
        // Another service receives this bot's messages: Pauline would never see Start.
        guard webhook.url.isEmpty else {
            throw TelegramAPI.Failure(
                code: nil, errorDescription: "This bot is already used by another service. Create a new bot with /newbot in BotFather."
            )
        }

        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let code = String((0..<16).map { _ in alphabet.randomElement()! })
        _ = await disconnect()
        config = TelegramConfig(token: token, botUsername: username, chatID: nil, linkCode: code, session: nil)
        config?.save()
        pollTask = Task { await poll() }
    }

    /// Leaves the chat in a clean state, then forgets the bot. A session still running gets a last message
    /// saying the chat stops here, a closing already queued gets a few seconds to go out.
    /// Returns why that last message could not leave, nil when it did.
    func disconnect() async -> String? {
        guard !leaving else { return nil }
        if isLinked, let start = activeStart, dropUnannouncedOpening(start) == false {
            enqueue(Outgoing(kind: .farewell(start), text: TelegramText.disconnected))
        }
        // From here on nothing may follow the last message: no polling, no new opening, notice or reply.
        leaving = true
        pollTask?.cancel()
        pollTask = nil
        await drain(timeout: 5)
        let stuck = outbox.contains(where: \.endsSession)
        let problem = stuck ? (sendProblem ?? "Telegram could not be reached in time, the chat keeps its previous message.") : nil
        stop()
        TelegramConfig.delete()
        config = nil
        return problem
    }

    /// Pauline quits while it stays on (pmset refused): the next launch closes the session with this reason.
    func keepOpenAfterQuit(_ reason: CloseReason) {
        quitEndReason = reason
        guard isLinked, let start = activeStart, config?.session?.start == start else { return }
        config?.session?.endReason = reason
        config?.save()
    }

    private func stop() {
        generation += 1
        leaving = false
        pollTask?.cancel()
        pollTask = nil
        worker?.cancel()
        worker = nil
        sending = nil
        outbox.removeAll()
        offset = nil
        sendProblem = nil
        pollProblem = nil
    }

    // MARK: Session

    /// Lines the chat up with the real state: an opening message once Pauline is on,
    /// a closing one when it went off without Pauline closing it (from Terminal, for example).
    func sync(_ state: PowerState) {
        guard isLinked, !leaving else { return }
        if state.sleepDisabled {
            if activeStart == nil {
                let start = Date()
                enqueue(Outgoing(kind: .opening(start), text: TelegramText.on(state), offButton: start))
            }
        } else if activeStart != nil {
            close(.elsewhere, state: state)
        }
    }

    /// Ends the session the chat sees as running, if any, with this reason.
    func close(_ reason: CloseReason, state: PowerState) {
        guard isLinked, !leaving, let start = activeStart else { return }
        // Reminders still waiting are no longer true.
        outbox.removeAll { $0.isNotice && $0.id != sending }
        // Turned on and off before the opening was ever tried: nothing was announced, nothing to close.
        if dropUnannouncedOpening(start) { return }

        let text = TelegramText.closed(reason, state: state)
        if config?.session?.start == start {
            config?.session?.closingText = text
            config?.save()
        }
        enqueue(Outgoing(kind: .closing(start), text: text))
    }

    /// A reminder, the charging message or a warning, with a Turn Pauline off button when asked.
    func notify(_ text: String, offButton: Bool) {
        guard isLinked, !leaving, let start = activeStart else { return }
        enqueue(Outgoing(kind: .notice, text: text, offButton: offButton ? start : nil))
    }

    func reply(_ text: String) {
        guard isLinked, !leaving else { return }
        enqueue(Outgoing(kind: .reply, text: text))
    }

    /// Waits until every queued message went out, or the timeout.
    func drain(timeout: TimeInterval) async {
        retryNow = true
        drains += 1
        defer { drains -= 1 }
        let deadline = Date().addingTimeInterval(timeout)
        while !outbox.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Removes the queued opening of this session, and its reminders, if it was never tried
    /// (the session is not on disk yet). Returns true when it did.
    private func dropUnannouncedOpening(_ start: Date) -> Bool {
        guard config?.session?.start != start,
              let index = outbox.firstIndex(where: { $0.isOpening && $0.session == start }),
              outbox[index].id != sending else { return false }
        outbox.remove(at: index)
        outbox.removeAll { $0.isNotice && $0.id != sending }
        return true
    }

    // MARK: Outbox

    /// Reminders and replies older than this are dropped rather than sent late.
    private static let staleAfter: TimeInterval = 120
    /// Retries start after `firstRetry` seconds and double up to `longRetry`, the wait for errors that last.
    private static let firstRetry = 5
    private static let longRetry = 60

    private func enqueue(_ item: Outgoing) {
        outbox.append(item)
        if item.session != nil {
            retryNow = true
        }
        if worker == nil {
            let generation = self.generation
            worker = Task { await runOutbox(generation) }
        }
    }

    private func runOutbox(_ generation: Int) async {
        var delay = Self.firstRetry
        while generation == self.generation, !Task.isCancelled,
              let item = outbox.first, let config, let chatID = config.chatID {
            let age = Date().timeIntervalSince(item.created)
            if item.session == nil, age > Self.staleAfter {
                outbox.removeFirst()
                continue
            }
            if case .opening(let start) = item.kind, config.session?.start != start {
                // Written before sending: if the answer is lost and Pauline stops, the next launch still closes it.
                self.config?.session = TelegramConfig.Session(
                    start: start, closingText: queuedClosingText(for: start), endReason: quitEndReason
                )
                self.config?.save()
            }

            let keyboard = item.offButton.map {
                TelegramAPI.Keyboard(inlineKeyboard: [[.init(text: TelegramText.offButton, callbackData: Self.offCallback($0))]])
            }
            let message = TelegramAPI.SendMessage(chatId: chatID, text: item.text, replyMarkup: keyboard)
            sending = item.id
            // Anything queued from now on, while the request is in flight, cuts the next wait short.
            retryNow = false
            var failure: TelegramAPI.Failure?
            do {
                let _: TelegramAPI.Ignored = try await TelegramAPI(token: config.token).call("sendMessage", message)
            } catch {
                failure = error as? TelegramAPI.Failure ?? TelegramAPI.Failure(code: nil, errorDescription: error.localizedDescription)
            }
            sending = nil
            guard generation == self.generation, outbox.first?.id == item.id else { continue }

            guard let failure else {
                sendProblem = nil
                delay = Self.firstRetry
                outbox.removeFirst()
                sent(item)
                continue
            }
            sendProblem = Self.lastingProblem(for: failure) ?? sendProblem
            // close() spared this reminder only because it was in flight. It failed, and its session is over.
            if item.isNotice, outbox.contains(where: \.endsSession) {
                outbox.removeFirst()
                continue
            }
            let lasting = [401, 403, 404].contains(failure.code ?? 0)
            if failure.code == 400 {
                // A malformed request never succeeds: give up on it rather than block the queue.
                outbox.removeFirst()
                sent(item)
                continue
            }
            if lasting, item.session == nil {
                outbox.removeFirst()
                continue
            }
            let wait = failure.retryAfter ?? (lasting ? Self.longRetry : (drains > 0 ? 1 : delay))
            if await backoff(seconds: wait, interruptible: failure.retryAfter == nil) {
                delay = Self.firstRetry
            } else if failure.retryAfter == nil {
                delay = min(delay * 2, Self.longRetry)
            }
        }
        if generation == self.generation {
            worker = nil
        }
    }

    /// Waits before a retry. A session message queued or a drain cuts the wait short, except a 429 retry_after.
    /// Returns true when cut short.
    private func backoff(seconds: Int, interruptible: Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline, !Task.isCancelled {
            if interruptible, retryNow {
                retryNow = false
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// The closing text already queued for a session whose opening is about to be sent.
    private func queuedClosingText(for start: Date) -> String? {
        outbox.first { item in
            if case .closing(let closing) = item.kind { return closing == start }
            return false
        }?.text
    }

    /// Erases the session once its closing or farewell went out.
    private func sent(_ item: Outgoing) {
        switch item.kind {
        case .closing(let start), .farewell(let start):
            if config?.session?.start == start {
                config?.session = nil
                config?.save()
            }
        case .opening, .notice, .reply:
            break
        }
    }

    /// The data of an off button, tied to the session it was sent in.
    private static func offCallback(_ session: Date) -> String {
        "off:\(Int(session.timeIntervalSince1970))"
    }

    private static func lastingProblem(for failure: TelegramAPI.Failure) -> String? {
        switch failure.code {
        case 401?, 404?: return "Telegram: the bot token no longer works, connect again"
        case 403?: return "Telegram: the bot is blocked, open its chat and tap Restart"
        case 409?: return "Telegram: another app or Mac reads this bot"
        default: return nil
        }
    }

    // MARK: Polling

    private func poll() async {
        var delay = Self.firstRetry
        while !Task.isCancelled, let config {
            do {
                let request = TelegramAPI.GetUpdates(offset: offset, timeout: 50, allowedUpdates: ["message", "callback_query"])
                let updates: [TelegramAPI.Update] = try await TelegramAPI(token: config.token)
                    .call("getUpdates", request, timeout: 65)
                pollProblem = nil
                delay = Self.firstRetry
                for update in updates where !Task.isCancelled {
                    offset = update.updateId + 1
                    handle(update)
                }
            } catch {
                let failure = error as? TelegramAPI.Failure
                pollProblem = failure.flatMap { Self.lastingProblem(for: $0) } ?? pollProblem
                // A dead token or a conflict will not fix itself on the first retry: ask less often.
                let wait: Int
                switch failure?.code {
                case 401?, 404?: wait = Self.longRetry
                case 409?: wait = 30
                default:
                    wait = failure?.retryAfter ?? delay
                    delay = min(delay * 2, Self.longRetry)
                }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func handle(_ update: TelegramAPI.Update) {
        guard let config else { return }

        if let query = update.callbackQuery {
            guard let chatID = config.chatID, query.message?.chat.id == chatID else {
                answer(query.id, nil)
                return
            }
            if let active = activeStart, query.data == Self.offCallback(active) {
                answer(query.id, nil)
                onCommand?(.off)
            } else {
                answer(query.id, activeStart == nil ? TelegramText.alreadyOff : TelegramText.staleButton)
            }
            return
        }

        guard let message = update.message, message.chat.type == "private", let text = message.text else { return }
        let words = text.split(separator: " ")
        // "/status@pauline_bot" is how commands look when picked from the menu in some clients.
        let command = words.first.flatMap { $0.split(separator: "@").first }.map { $0.lowercased() } ?? ""

        guard let chatID = config.chatID else {
            if command == "/start", words.count == 2, String(words[1]) == config.linkCode {
                link(message.chat.id)
            } else {
                fireAndForget("sendMessage", TelegramAPI.SendMessage(chatId: message.chat.id, text: TelegramText.useTheLink, replyMarkup: nil))
            }
            return
        }
        guard message.chat.id == chatID else { return }

        let sentAt = Date(timeIntervalSince1970: TimeInterval(message.date))
        switch command {
        case "/status":
            // Typed while the Mac slept, it arrives on wake: past a few minutes the answer is not wanted.
            guard Date().timeIntervalSince(sentAt) < 300 else { return }
            onCommand?(.status)
        case "/off":
            guard let active = activeStart else {
                reply(TelegramText.alreadyOff)
                return
            }
            // Typed before Pauline was turned on again: it was meant for the previous session.
            // 10 s of slack for the gap between Telegram's clock and the Mac's.
            if sentAt.addingTimeInterval(10) < active {
                reply(TelegramText.lateOff)
            } else {
                onCommand?(.off)
            }
        default:
            reply(TelegramText.help)
        }
    }

    private func link(_ chatID: Int64) {
        config?.chatID = chatID
        config?.linkCode = nil
        config?.save()
        setCommands()
        reply(TelegramText.connected)
    }

    private func answer(_ queryID: String, _ text: String?) {
        fireAndForget("answerCallbackQuery", TelegramAPI.AnswerCallback(callbackQueryId: queryID, text: text))
    }

    private func setCommands() {
        let commands = TelegramText.commands.map { TelegramAPI.BotCommand(command: $0.command, description: $0.description) }
        fireAndForget("setMyCommands", TelegramAPI.SetCommands(commands: commands))
    }

    /// A request outside the outbox, for calls that do not matter if they are lost.
    private func fireAndForget<Body: Encodable & Sendable>(_ method: String, _ body: Body) {
        guard let token = config?.token else { return }
        Task {
            let _: TelegramAPI.Ignored? = try? await TelegramAPI(token: token).call(method, body)
        }
    }
}
