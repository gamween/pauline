import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import PaulineCore

/// The bot token, the linked chat and the open session, kept in
/// ~/Library/Application Support/Pauline/telegram.json. The folder is private to the user (0700)
/// and the file too (0600). Not the Keychain on purpose: every local rebuild changes the ad hoc
/// signature, and macOS would ask for the password again.
struct TelegramConfig: Codable, Equatable {
    var token: String
    var botUsername: String
    /// Set once the user taps Start in the chat with the bot.
    var chatID: Int64?
    /// Secret carried by the Start link, so only that tap can link a chat.
    var linkCode: String?
    /// The stay awake session whose opening message was sent (or tried) and whose closing message has not gone out yet.
    var session: Session?

    struct Session: Codable, Equatable {
        var start: Date
        /// The closing message as it reads when sent late, written the moment the session ends,
        /// so a crash or a restart before it goes out still closes the session with the right words.
        var closingText: String?
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
        return try? decoder.decode(TelegramConfig.self, from: data)
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
        try? FileManager.default.removeItem(at: file)
    }
}

/// A thin client for the few Bot API methods Pauline uses.
struct TelegramAPI: Sendable {
    let token: String

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

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope<Result>.self, from: data) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            throw Failure(code: status, errorDescription: "Telegram sent an unexpected answer.")
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
        let commands: [Command]
    }

    struct Command: Encodable, Sendable {
        let command: String
        let description: String
    }

    struct Ignored: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }
}

/// Talks to the user's own bot. No server involved: Pauline asks Telegram for new messages with long polling.
///
/// Every stay awake session gets an opening message and, whatever ends it, a closing message that stays
/// the last one of the session. Messages leave one at a time, in order, from an outbox. A session is written
/// to disk before its opening is sent and erased once its closing went out, so a crash, a power loss or a
/// network outage still ends with a closing message, on the next launch at the latest.
@MainActor
final class TelegramBot {
    enum Command {
        case status
        case off
    }

    /// Called for each command from the linked chat.
    var onCommand: ((Command) -> Void)?

    private(set) var config = TelegramConfig.load()
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
    private var pollTask: Task<Void, Never>?
    private var offset: Int?

    struct Outgoing {
        enum Kind {
            /// Opens the session that started at this date.
            case opening(Date)
            /// A reminder or the charging message, dropped once the session closes or after 2 minutes.
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
        /// The session an Allow sleep button belongs to.
        var button: Date?

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

    /// The link that opens the bot chat with the secret code, while waiting for Start.
    var startLink: URL? {
        guard let config, let code = config.linkCode else { return nil }
        return URL(string: "https://t.me/\(config.botUsername)?start=\(code)")
    }

    // MARK: Lifecycle

    /// Starts listening. A session left open by a quit while offline, a crash or a restart gets its closing now.
    func start(bootedAt boot: Date?, state: PowerState) {
        guard let config else { return }
        if let session = config.session {
            let text = session.closingText ?? TelegramText.closed(
                (boot.map { $0 > session.start } ?? false) ? .restart : .crash, state: state
            )
            enqueue(Outgoing(kind: .closing(session.start), text: text))
        }
        if isLinked {
            setCommands()
        }
        pollTask = Task { await poll() }
    }

    /// Checks the token with Telegram, saves it and returns the link to tap Start.
    func connect(token raw: String) async throws -> URL {
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
        await disconnect()
        config = TelegramConfig(token: token, botUsername: username, chatID: nil, linkCode: code, session: nil)
        config?.save()
        pollTask = Task { await poll() }
        return startLink!
    }

    /// Leaves the chat in a clean state, then forgets the bot. A session still running gets a last message
    /// saying the chat stops here, a closing already queued gets a few seconds to go out.
    func disconnect() async {
        if isLinked, let start = activeStart {
            if dropUnannouncedOpening(start) == false {
                enqueue(Outgoing(kind: .farewell(start), text: TelegramText.disconnected))
            }
        }
        await drain(timeout: 5)
        stop()
        TelegramConfig.delete()
        config = nil
    }

    private func stop() {
        generation += 1
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

    /// Lines the chat up with the real state: an opening message once stay awake is on,
    /// a closing one when it went off without Pauline closing it (from Terminal, for example).
    func sync(_ state: PowerState) {
        guard isLinked else { return }
        if state.sleepDisabled {
            if activeStart == nil {
                let start = Date()
                enqueue(Outgoing(kind: .opening(start), text: TelegramText.on(state), button: start))
            }
        } else if activeStart != nil {
            close(.elsewhere, state: state)
        }
    }

    /// Ends the session the chat sees as running, if any, with this reason.
    func close(_ reason: CloseReason, state: PowerState) {
        guard isLinked, let start = activeStart else { return }
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

    /// A reminder or the charging message, with an Allow sleep button when asked.
    func notify(_ text: String, allowSleepButton: Bool) {
        guard isLinked, let start = activeStart else { return }
        enqueue(Outgoing(kind: .notice, text: text, button: allowSleepButton ? start : nil))
    }

    func reply(_ text: String) {
        guard isLinked else { return }
        enqueue(Outgoing(kind: .reply, text: text))
    }

    /// Waits until every queued message went out, or the timeout.
    func drain(timeout: TimeInterval) async {
        retryNow = true
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
        var delay = 5
        while generation == self.generation, !Task.isCancelled,
              let item = outbox.first, let config, let chatID = config.chatID {
            let age = Date().timeIntervalSince(item.created)
            if item.session == nil, age > 120 {
                outbox.removeFirst()
                continue
            }
            if case .opening(let start) = item.kind, config.session?.start != start {
                // Written before sending: if the answer is lost and Pauline stops, the next launch still closes it.
                self.config?.session = TelegramConfig.Session(start: start, closingText: queuedClosingText(for: start))
                self.config?.save()
            }

            let keyboard = item.button.map {
                TelegramAPI.Keyboard(inlineKeyboard: [[.init(text: TelegramText.allowSleepButton, callbackData: "off:\(Int($0.timeIntervalSince1970))")]])
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
                delay = 5
                outbox.removeFirst()
                sent(item)
                continue
            }
            sendProblem = Self.problem(failure) ?? sendProblem
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
            if await backoff(seconds: failure.retryAfter ?? (lasting ? 60 : delay), interruptible: failure.retryAfter == nil) {
                delay = 5
            } else if failure.retryAfter == nil {
                delay = min(delay * 2, 60)
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

    private static func problem(_ failure: TelegramAPI.Failure) -> String? {
        switch failure.code {
        case 401?, 404?: return "Telegram: the bot token no longer works, connect again"
        case 403?: return "Telegram: the bot is blocked, open its chat and tap Restart"
        case 409?: return "Telegram: another app or Mac reads this bot"
        default: return nil
        }
    }

    // MARK: Polling

    private func poll() async {
        var delay = 5
        while !Task.isCancelled, let config {
            do {
                let request = TelegramAPI.GetUpdates(offset: offset, timeout: 50, allowedUpdates: ["message", "callback_query"])
                let updates: [TelegramAPI.Update] = try await TelegramAPI(token: config.token)
                    .call("getUpdates", request, timeout: 65)
                pollProblem = nil
                delay = 5
                for update in updates where !Task.isCancelled {
                    offset = update.updateId + 1
                    handle(update)
                }
            } catch {
                let failure = error as? TelegramAPI.Failure
                pollProblem = failure.flatMap(Self.problem) ?? pollProblem
                // A dead token or a conflict will not fix itself in 5 s: ask less often.
                let wait: Int
                switch failure?.code {
                case 401?, 404?: wait = 60
                case 409?: wait = 30
                default:
                    wait = failure?.retryAfter ?? delay
                    delay = min(delay * 2, 60)
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
            let session = query.data.flatMap { $0.hasPrefix("off:") ? Int($0.dropFirst(4)) : nil }
            if let session, let active = activeStart, session == Int(active.timeIntervalSince1970) {
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
                let notice = TelegramAPI.SendMessage(chatId: message.chat.id, text: TelegramText.useTheLink, replyMarkup: nil)
                let token = config.token
                Task {
                    let _: TelegramAPI.Ignored? = try? await TelegramAPI(token: token).call("sendMessage", notice)
                }
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
            // Typed before stay awake was turned on again: it was meant for the previous session.
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
        guard let token = config?.token else { return }
        Task {
            let _: TelegramAPI.Ignored? = try? await TelegramAPI(token: token)
                .call("answerCallbackQuery", TelegramAPI.AnswerCallback(callbackQueryId: queryID, text: text))
        }
    }

    private func setCommands() {
        guard let token = config?.token else { return }
        let commands = TelegramText.commands.map { TelegramAPI.Command(command: $0.command, description: $0.description) }
        Task {
            let _: TelegramAPI.Ignored? = try? await TelegramAPI(token: token)
                .call("setMyCommands", TelegramAPI.SetCommands(commands: commands))
        }
    }
}

/// The Start link as a QR code, for a phone when Telegram is not installed on the Mac.
func qrCode(for url: URL, size: CGFloat) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scale = size / output.extent.width
    let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}
