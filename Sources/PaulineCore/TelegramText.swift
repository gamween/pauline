import Foundation

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

/// Everything the Telegram bot says. "Off" always means stay awake is off, never that the Mac shuts down.
public enum TelegramText {
    public static let commands: [(command: String, description: String)] = [
        ("status", "Battery, charging and stay awake"),
        ("off", "Stop keeping the Mac awake, it sleeps normally again"),
    ]

    public static let help = """
        /status  battery, charging and stay awake
        /off  stop keeping the Mac awake
        """

    public static let connected = """
        Pauline is connected. Each time your Mac stays awake you get an opening message, \
        reminders at 30%, 20% and 10% battery, a message when charging is done, \
        and a closing message when it sleeps normally again.

        \(help)
        """

    public static let allowSleepButton = "Allow sleep"
    public static let alreadyOff = "Stay awake is already off."
    public static let lateOff = "Your /off was sent before stay awake was turned on again. Send /off again to turn it off."
    public static let staleButton = "This button is from an earlier session."
    public static let useTheLink = "To connect, open the link Pauline shows on your Mac."
    public static let couldNotTurnOff =
        "Pauline could not turn stay awake off, your Mac is still awake. Run ./install.sh again on the Mac."
    public static let quitStillAwake =
        "Pauline quit but could not turn stay awake off, your Mac is still awake. Run ./install.sh again on the Mac."
    /// The last message when Telegram is disconnected while stay awake is still on. It must not say "off".
    public static let disconnected =
        "Pauline is disconnected from this chat. Stay awake is still on, you will get no more messages here."

    public static func started(_ state: PowerState) -> String {
        "Stay awake is on, \(lid(state)).\n\(battery(state))"
    }

    public static func reminder(percent: Int, state: PowerState, policy: Policy) -> String {
        let left = state.onBattery ? state.minutesToEmpty.map { ", \(duration($0)) left" } ?? "" : ""
        var text = "Battery at \(percent)%\(left). Your Mac is still awake, \(lid(state))."
        if policy.batteryFloor > 0 {
            text += " Stay awake turns off on its own at \(policy.batteryFloor)%."
        }
        return text
    }

    public static func chargingDone(percent: Int) -> String {
        "Charging done at \(percent)%. Running on the power adapter."
    }

    /// The last message of a session.
    /// - Parameters:
    ///   - end: when it ended, nil when unknown (crash, restart).
    ///   - sleeping: true when a closed Mac goes to sleep now, false when normal sleep is back,
    ///     nil to say nothing about it (sent late, or the Mac is shutting down).
    ///   - now: the moment the text is written, to add the day when it is not today.
    public static func closed(
        _ reason: CloseReason, start: Date, end: Date?, sleeping: Bool?, policy: Policy,
        timeZone: TimeZone = .current, now: Date = Date()
    ) -> String {
        var lines = ["Stay awake is off. \(sentence(reason, policy: policy))"]
        if let end {
            // Counted between whole minutes, so it matches the two times printed next to it.
            let minutes = max(0, Int(end.timeIntervalSince1970 / 60) - Int(start.timeIntervalSince1970 / 60))
            let from = clock(start, timeZone, today: end), to = clock(end, timeZone, today: now)
            lines.append("On from \(from) to \(to) (\(duration(minutes))).")
        } else {
            lines.append("It had been on since \(clock(start, timeZone, today: now)).")
        }
        switch sleeping {
        case true?: lines.append("Your Mac is going to sleep.")
        case false?: lines.append("Normal sleep is back.")
        case nil: break
        }
        return lines.joined(separator: "\n")
    }

    public static func status(_ state: PowerState) -> String {
        let mode = state.sleepDisabled ? "on, \(lid(state))" : "off"
        return "Stay awake: \(mode)\n\(battery(state))"
    }

    public static func battery(_ state: PowerState) -> String {
        guard let percent = state.batteryPercent else { return "No battery" }
        if state.onBattery {
            guard let minutes = state.minutesToEmpty else { return "Battery: \(percent)%, not charging" }
            return "Battery: \(percent)%, not charging, \(duration(minutes)) left"
        }
        guard state.batteryCharging else {
            return "Battery: \(percent)%, not charging, on power adapter"
        }
        guard let minutes = state.minutesToFull else {
            return "Battery: \(percent)%, charging"
        }
        return "Battery: \(percent)%, charging, full in \(duration(minutes))"
    }

    public static func duration(_ minutes: Int) -> String {
        if minutes < 1 { return "under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private static func sentence(_ reason: CloseReason, policy: Policy) -> String {
        switch reason {
        case .mac: return "Turned off on the Mac."
        case .telegram: return "Turned off from Telegram."
        case .lowBattery: return "Battery reached \(policy.batteryFloor)%."
        case .overheating: return "The Mac got too hot."
        case .quit: return "Pauline was quit."
        case .stopped: return "Pauline was stopped."
        case .shutdown: return "The Mac shut down, restarted or logged out."
        case .crash: return "Pauline stopped unexpectedly and started again."
        case .restart: return "The Mac restarted."
        case .elsewhere: return "Turned off outside Pauline."
        }
    }

    /// "14:32", or "Mon 14:32" when it is not the same day as `today`.
    private static func clock(_ date: Date, _ timeZone: TimeZone, today: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: today) else { return time }
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return "\(days[((parts.weekday ?? 1) - 1) % 7]) \(time)"
    }

    private static func lid(_ state: PowerState) -> String {
        state.lidClosed ? "lid closed" : "lid open"
    }
}
