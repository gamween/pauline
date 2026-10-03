/// The menu and tooltip texts that change with the state, and the alert when the battery or the heat stops Pauline from turning on.
public enum StatusText {
    public static func headline(_ state: PowerState) -> String {
        state.sleepDisabled ? "Awake, even with the lid closed" : "Sleeping normally"
    }

    public static func battery(_ state: PowerState, policy: Policy) -> String? {
        guard let percent = state.batteryPercent else { return nil }
        if !state.onBattery {
            return state.batteryCharging ? "Battery \(percent)%, charging" : "Battery \(percent)%, plugged in"
        }
        guard policy.batteryFloor > 0 else { return "Battery \(percent)%, no battery floor" }
        return "Battery \(percent)%, sleeps again at \(policy.batteryFloor)%"
    }

    public static func toggleTitle(_ state: PowerState) -> String {
        state.sleepDisabled ? "Allow Sleep" : "Stay Awake"
    }

    public static func tooltip(_ state: PowerState) -> String {
        let next = state.sleepDisabled ? "allow sleep again" : "stay awake with the lid closed"
        return "Pauline: \(headline(state).lowercased()). Click to \(next), right-click for more."
    }

    /// Title and message of the alert shown when staying awake is refused.
    public static func refusal(_ danger: Danger, policy: Policy) -> (title: String, message: String) {
        switch danger {
        case .lowBattery:
            return (
                "Battery too low",
                "Pauline lets the Mac sleep at \(policy.batteryFloor)% when the battery is not charging. "
                    + "Plug in a power adapter first."
            )
        case .overheating:
            return ("Mac too hot", "macOS reports a critical temperature. Let it cool down first.")
        }
    }
}
