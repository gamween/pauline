/// Why Pauline turned off, told in the closing message.
public enum CloseReason: String, Codable, Sendable, CaseIterable {
    /// The menu bar icon or its menu.
    case mac
    /// `/off` or the Turn Pauline off button.
    case telegram
    case lowBattery
    case overheating
    /// Quit in the menu.
    case quit
    /// Stopped by a signal, for example while reinstalling.
    case stopped
    /// Shutdown, or a logout or restart macOS did not name.
    case shutdown
    case logout
    /// A restart chosen in macOS.
    case restarting
    /// Pauline crashed, launchd started it again.
    case crash
    /// The Mac restarted without a clean shutdown: power loss, kernel panic, forced restart.
    case unexpectedRestart
    /// `pmset -a disablesleep 0` run outside Pauline.
    case elsewhere

    /// Pauline gave sleep back on its own.
    public init(_ danger: Danger) {
        switch danger {
        case .lowBattery: self = .lowBattery
        case .overheating: self = .overheating
        }
    }
}

/// Everything the Telegram bot says: whether Pauline is on or off, then the battery.
/// "Off" always means Pauline stopped keeping the Mac awake, never that the Mac shuts down.
public enum TelegramText {
    /// The bot menu in Telegram.
    public static let commands: [(command: String, description: String)] = [
        ("status", "Battery and state"),
        ("off", "Turn Pauline off, the Mac sleeps normally again"),
    ]

    /// The answer to anything that is not a command.
    public static let help = commands.map { "/\($0.command)  \($0.description)" }.joined(separator: "\n")

    public static let connected = "Pauline is connected.\n\n\(help)"

    public static let offButton = "Turn Pauline off"
    public static let alreadyOff = "Pauline is already off"
    public static let lateOff = "Pauline was turned on again after your /off. Send /off again to turn it off."
    public static let staleButton = "This button is from an earlier session."
    public static let useTheLink = "To connect, open the link Pauline shows on your Mac."
    public static let couldNotTurnOff = "Pauline is still on, it could not turn off. Run ./install.sh again on the Mac."
    public static let quitStillOn = "Pauline quit but is still on. Run ./install.sh again on the Mac."
    /// The last message when Telegram is disconnected while Pauline is still on. It must not say "off".
    public static let disconnected = "Pauline is disconnected from this chat. It is still on."

    /// The opening message, the reminders, the charging message and /status: the state, then the battery.
    public static func on(_ state: PowerState) -> String {
        "Pauline is on\n\(battery(state))"
    }

    public static func status(_ state: PowerState) -> String {
        state.sleepDisabled ? on(state) : "Pauline is off\n\(battery(state))"
    }

    /// The closing message. A short reason only when it was not turned off by hand.
    public static func closed(_ reason: CloseReason, state: PowerState) -> String {
        let tag: String
        switch reason {
        case .lowBattery: tag = " (battery low)"
        case .overheating: tag = " (too hot)"
        case .shutdown: tag = " (Mac shut down)"
        case .logout: tag = " (logged out)"
        case .restarting: tag = " (Mac restarting)"
        case .crash: tag = " (Pauline crashed)"
        case .unexpectedRestart: tag = " (Mac restarted)"
        case .mac, .telegram, .quit, .stopped, .elsewhere: tag = ""
        }
        return "Pauline is off\(tag)\n\(battery(state))"
    }

    static func battery(_ state: PowerState) -> String {
        guard let percent = state.batteryPercent else { return "No battery" }
        if state.onBattery {
            guard let minutes = state.minutesToEmpty else { return "Battery \(percent)%, on battery" }
            return "Battery \(percent)%, \(duration(minutes)) left"
        }
        if state.batteryCharging {
            guard let minutes = state.minutesToFull else { return "Battery \(percent)%, charging" }
            return "Battery \(percent)%, charging, full in \(duration(minutes))"
        }
        return state.chargeComplete ? "Battery \(percent)%, charged" : "Battery \(percent)%, plugged in, not charging"
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 1 { return "under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
