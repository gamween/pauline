/// Why stay awake ended, told in the closing message.
public enum CloseReason: String, Codable, Sendable, CaseIterable {
    /// The switch or the menu.
    case mac
    /// `/off` or an Allow sleep button.
    case telegram
    case lowBattery
    case overheating
    /// Quit in the menu.
    case quit
    /// Stopped by a signal, for example while reinstalling.
    case stopped
    /// Shutdown, restart or logout.
    case shutdown
    /// Pauline crashed, launchd started it again.
    case crash
    /// The Mac restarted without a clean shutdown: power loss, kernel panic, forced restart.
    case restart
    /// `pmset -a disablesleep 0` run outside Pauline.
    case elsewhere
}

/// Everything the Telegram bot says. Sober on purpose: whether Pauline is on or off, then the battery.
/// "Off" always means Pauline stopped keeping the Mac awake, never that the Mac shuts down.
public enum TelegramText {
    public static let commands: [(command: String, description: String)] = [
        ("status", "Battery and state"),
        ("off", "Turn Pauline off, the Mac sleeps normally again"),
    ]

    public static let help = """
        /status  battery and state
        /off  turn Pauline off
        """

    public static let connected = "Pauline is connected.\n\n\(help)"

    public static let allowSleepButton = "Turn Pauline off"
    public static let alreadyOff = "Pauline is already off"
    public static let lateOff = "Pauline was turned on again after your /off. Send /off again to turn it off."
    public static let staleButton = "This button is from an earlier session."
    public static let useTheLink = "To connect, open the link Pauline shows on your Mac."
    public static let couldNotTurnOff = "Pauline is still on, it could not turn off. Run ./install.sh again on the Mac."
    public static let quitStillAwake = "Pauline quit but is still on. Run ./install.sh again on the Mac."
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
        case .crash: tag = " (Pauline crashed)"
        case .restart: tag = " (Mac restarted)"
        case .mac, .telegram, .quit, .stopped, .elsewhere: tag = ""
        }
        return "Pauline is off\(tag)\n\(battery(state))"
    }

    public static func battery(_ state: PowerState) -> String {
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

    public static func duration(_ minutes: Int) -> String {
        if minutes < 1 { return "under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
